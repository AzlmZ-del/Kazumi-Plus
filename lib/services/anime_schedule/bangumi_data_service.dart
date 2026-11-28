import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/modules/bangumi/bangumi_data_snapshot.dart';
import 'package:kazumi/modules/bangumi/site_schedule.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/rules_mirror.dart';
import 'package:path_provider/path_provider.dart';

/// 从 bangumi-data 取「每日放送时刻 + 平台」。
///
/// 上游是全量数据集（8 MB），这里在 isolate 里瘦身成只含最近一年在放送条目
/// 的精简结构落盘，之后按周在本地展开循环规则，不再联网。
class BangumiDataService {
  BangumiDataService._();

  static final BangumiDataService instance = BangumiDataService._();

  static const String _dataPath = 'dist/data.json';

  /// 瘦身窗口：往前保留一年（历史季仍可回看），往后留半年（已定档的下一季）。
  static const int _keepPastDays = 400;
  static const int _keepFutureDays = 400;

  /// 缓存有效期：bangumi-data 每天由 CI 更新一次，半天足够新。
  static const Duration _cacheTtl = Duration(hours: 12);

  static String get _dataUrlDirect =>
      'https://raw.githubusercontent.com/bangumi-data/bangumi-data/master/'
      '$_dataPath';

  /// 按规则加速档位改写数据源地址。
  ///
  /// [RulesMirror.map] 只认内置规则仓库，这里用它的前缀/路径式改写能力，
  /// 拿不到就退回 GitHub raw。
  static String get _dataUrl {
    final mirror = RulesMirror.current;
    final mapped = mirror.map(_dataUrlDirect);
    if (mapped != null) return mapped;
    final prefix = mirror.prefixOrNull;
    if (prefix != null) return '$prefix$_dataUrlDirect';
    return _dataUrlDirect;
  }

  BangumiDataSnapshot? _snapshot;
  Future<BangumiDataSnapshot?>? _loading;
  bool _refreshing = false;

  /// 每次快照更新后自增，页面据此重建。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  DateTime? get fetchedAt => _snapshot?.fetchedAt;

  /// 直接注入快照，供测试与离线校验使用。
  @visibleForTesting
  void debugLoadSnapshot(BangumiDataSnapshot snapshot) {
    _snapshot = snapshot;
    revision.value++;
  }

  /// 只读本地缓存；没有缓存时返回 null 且不联网。
  Future<BangumiDataSnapshot?> ensureLoaded() {
    final cached = _snapshot;
    if (cached != null) return Future.value(cached);
    return _loading ??= _loadFromDisk();
  }

  Future<BangumiDataSnapshot?> _loadFromDisk() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final snapshot = BangumiDataSnapshot.decode(raw);
      if (snapshot == null) {
        KazumiLogger().w('BangumiDataService: 缓存格式不兼容，忽略');
        return null;
      }
      _snapshot = snapshot;
      return snapshot;
    } catch (error, stackTrace) {
      KazumiLogger().w(
        'BangumiDataService: 读取缓存失败',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    } finally {
      _loading = null;
    }
  }

  bool get _stale {
    final at = _snapshot?.fetchedAt;
    if (at == null) return true;
    return DateTime.now().difference(at) > _cacheTtl;
  }

  /// 后台刷新：缓存过期或首次启动时拉取上游。
  ///
  /// 失败静默保留旧数据，调用方用 unawaited，不要 await。
  Future<void> refreshInBackground({bool force = false}) async {
    if (_refreshing) return;
    if (!force && !_stale) return;
    _refreshing = true;
    try {
      final response = await DioFactory.pluginDio.get<String>(
        _dataUrl,
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 60),
          // 上游 CI 每天重建，拿不到 304 也无所谓，这里只按时间判断新旧。
          headers: {HttpHeaders.acceptEncodingHeader: 'gzip'},
        ),
      );
      final raw = response.data;
      if (raw == null || raw.length < 1024) {
        KazumiLogger().w('BangumiDataService: 上游响应异常，保留旧数据');
        return;
      }
      final slim = await compute(_pruneBangumiData, raw);
      if (slim == null || slim.isEmpty) return;
      final snapshot = BangumiDataSnapshot.decode(slim);
      if (snapshot == null) {
        KazumiLogger().w('BangumiDataService: 瘦身结果无法解析');
        return;
      }
      final file = await _cacheFile();
      // 原子写：进程被杀时不留半截缓存。
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(slim, flush: true);
      await temp.rename(file.path);
      _snapshot = snapshot;
      revision.value++;
      KazumiLogger().i(
        'BangumiDataService: 刷新完成，${snapshot.items.length} 条在放送条目',
      );
    } catch (error, stackTrace) {
      KazumiLogger().w(
        'BangumiDataService: 刷新失败，保留旧数据',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _refreshing = false;
    }
  }

  static Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    // writeAsString 不建父目录，首次落盘会 PathNotFoundException。
    final target = Directory('${dir.path}/anime_schedule');
    if (!target.existsSync()) {
      await target.create(recursive: true);
    }
    return File('${target.path}/bangumi_data.json');
  }

  /// 展开某一周的放送事件。
  ///
  /// 返回 `bgmId -> 本地日期键(YYYY-MM-DD) -> 当日平台与时刻`。
  /// [monday] 取本地时区当天 00:00，覆盖周一到周日。
  Map<int, Map<String, SiteSchedule>> buildWeek(DateTime monday) {
    final snapshot = _snapshot;
    if (snapshot == null) return const {};
    final start = DateTime(monday.year, monday.month, monday.day);
    // 多展开一天：周日深夜的平台档期可能落在下周一凌晨。
    final end = DateTime(start.year, start.month, start.day + 8);

    final result = <int, Map<String, SiteSchedule>>{};
    for (final item in snapshot.items) {
      // 已完结的条目即使循环规则还在也会被展开，先按区间挡掉。
      final finish = item.end;
      if (finish != null && finish.isBefore(start)) continue;
      final first = item.begin;
      if (first != null && first.isAfter(end)) continue;
      final entries = _buildItemWeek(item, snapshot.sites, start, end);
      if (entries == null || entries.isEmpty) continue;
      result[item.bgmId] = entries;
    }
    return result;
  }

  Map<String, SiteSchedule>? _buildItemWeek(
    BangumiDataItem item,
    Map<String, BangumiSiteMeta> siteMeta,
    DateTime start,
    DateTime end,
  ) {
    final broadcast = <DateTime>[
      if (item.broadcastRule != null)
        ...expandRrule(item.broadcastRule!, start, end),
    ];

    // 平台事件按本地日期分桶。
    final platforms = <String, List<_PlatformEvent>>{};
    for (final site in item.sites) {
      final rule = site.rule;
      if (rule == null) continue;
      final meta = siteMeta[site.site];
      if (meta == null || !meta.isOnAir) continue;
      for (final at in expandRrule(rule, start, end)) {
        final local = at.toLocal();
        final key = localDateKey(local);
        final url = meta.urlFor(site.id);
        (platforms[key] ??= []).add(
          _PlatformEvent(
            name: meta.title,
            at: local,
            url: url,
            regions: meta.regions,
          ),
        );
      }
    }
    if (platforms.isEmpty) return null;

    final entries = <String, SiteSchedule>{};
    for (var day = 0; day < 7; day++) {
      final date = DateTime(start.year, start.month, start.day + day);
      final key = localDateKey(date);
      final nextKey = localDateKey(
        DateTime(date.year, date.month, date.day + 1),
      );
      final today = platforms[key] ?? const <_PlatformEvent>[];

      // 放送日锚点：条目级规则落在这一本地日期的那一次。
      DateTime? anchor;
      for (final at in broadcast) {
        final local = at.toLocal();
        if (localDateKey(local) == key) {
          anchor = local;
          break;
        }
      }

      // 「次日」后缀：平台时刻落在放送日之后的那一天，且不超过 24 小时。
      final following = <_PlatformEvent>[];
      if (anchor != null) {
        for (final event in platforms[nextKey] ?? const <_PlatformEvent>[]) {
          if (event.at.difference(anchor).inHours <= 24) {
            following.add(event);
          }
        }
      }

      if (today.isEmpty && following.isEmpty) continue;

      final ordered = [...today, ...following]
        ..sort((a, b) => a.at.compareTo(b.at));
      entries[key] = SiteSchedule(
        airTime: anchor ?? (today.isNotEmpty ? today.first.at : null),
        platforms: [
          for (final event in ordered)
            SchedulePlatform(
              name: event.name,
              time:
                  '${following.contains(event) ? '次日 ' : ''}'
                  '${_formatHm(event.at)}',
              url: event.url,
              regions: event.regions,
            ),
        ],
      );
    }
    return entries.isEmpty ? null : entries;
  }

  static String _formatHm(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class _PlatformEvent {
  const _PlatformEvent({
    required this.name,
    required this.at,
    required this.url,
    required this.regions,
  });

  final String name;
  final DateTime at;
  final String? url;
  final List<String> regions;
}

/// 展开 ISO 8601 循环规则，只支持 bangumi-data 实际出现的 `R/<时刻>/P<n>D`。
///
/// 超出支持范围一律返回空列表：宁可少显示档期，也不猜一个错误时刻。
List<DateTime> expandRrule(String rule, DateTime from, DateTime to) {
  if (!rule.startsWith('R/')) return const [];
  final parts = rule.split('/');
  if (parts.length != 3) return const [];
  final anchor = DateTime.tryParse(parts[1])?.toUtc();
  if (anchor == null) return const [];
  final period = parts[2];
  if (!period.startsWith('P') || !period.endsWith('D')) return const [];
  final days = int.tryParse(period.substring(1, period.length - 1));
  if (days == null || days <= 0) return const [];
  final step = Duration(days: days);
  final startUtc = from.toUtc();
  final endUtc = to.toUtc();
  if (anchor.isAfter(endUtc)) return const [];

  var cursor = anchor;
  if (cursor.isBefore(startUtc)) {
    final skipped = startUtc.difference(cursor).inMicroseconds;
    final stepMicros = step.inMicroseconds;
    final periods = skipped ~/ stepMicros + (skipped % stepMicros == 0 ? 0 : 1);
    cursor = cursor.add(step * periods);
  }
  final result = <DateTime>[];
  // 上限兜底：正常一周最多 8 次，防止异常规则把循环拖死。
  while (!cursor.isAfter(endUtc) && result.length < 32) {
    result.add(cursor);
    cursor = cursor.add(step);
  }
  return result;
}

/// 在 isolate 中把全量 data.json 瘦身成时间表快照。
@visibleForTesting
String? pruneBangumiData(String raw) => _pruneBangumiData(raw);

String? _pruneBangumiData(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final rawSites = decoded['siteMeta'];
    final rawItems = decoded['items'];
    if (rawSites is! Map || rawItems is! List) return null;

    final sites = <String, BangumiSiteMeta>{};
    rawSites.forEach((key, value) {
      if (key is! String || value is! Map) return;
      final title = value['title'];
      if (title is! String) return;
      final rawRegions = value['regions'];
      sites[key] = BangumiSiteMeta(
        key: key,
        title: title,
        type: (value['type'] as String?) ?? '',
        urlTemplate: value['urlTemplate'] as String?,
        regions: [
          if (rawRegions is List)
            for (final region in rawRegions)
              if (region is String) region,
        ],
      );
    });

    final now = DateTime.now().toUtc();
    final keepFrom = now.subtract(
      const Duration(days: BangumiDataService._keepPastDays),
    );
    final keepTo = now.add(
      const Duration(days: BangumiDataService._keepFutureDays),
    );

    final items = <BangumiDataItem>[];
    for (final entry in rawItems) {
      if (entry is! Map) continue;
      final parsed = _pruneItem(entry, sites, keepFrom, keepTo);
      if (parsed != null) items.add(parsed);
    }
    if (items.isEmpty) return null;
    return BangumiDataSnapshot(
      fetchedAt: DateTime.now(),
      items: items,
      sites: sites,
    ).encode();
  } catch (_) {
    return null;
  }
}

BangumiDataItem? _pruneItem(
  Map<Object?, Object?> raw,
  Map<String, BangumiSiteMeta> sites,
  DateTime keepFrom,
  DateTime keepTo,
) {
  final rawSites = raw['sites'];
  if (rawSites is! List) return null;

  int? bgmId;
  final kept = <BangumiSiteEntry>[];
  for (final site in rawSites) {
    if (site is! Map) continue;
    final key = site['site'];
    final id = site['id'];
    if (key is! String || id is! String) continue;
    if (key == 'bangumi') bgmId = int.tryParse(id);
    final meta = sites[key];
    // 只保留放送平台：资料站和资源站进不了时间表。
    if (meta == null || !meta.isOnAir) continue;
    final rule = site['broadcast'];
    kept.add(
      BangumiSiteEntry(
        site: key,
        id: id,
        rule: rule is String && rule.isNotEmpty ? rule : null,
      ),
    );
  }
  if (bgmId == null || kept.isEmpty) return null;

  final begin = parseUtcIso(raw['begin']);
  final end = parseUtcIso(raw['end']);
  // 无首播日的条目无法判断是否在放送窗口内，直接按区间外处理。
  if (begin == null && end == null) return null;
  if (end != null && end.isBefore(keepFrom)) return null;
  if (begin != null && begin.isAfter(keepTo)) return null;

  final translate = raw['titleTranslate'];
  var zh = '';
  if (translate is Map) {
    for (final locale in const ['zh-Hans', 'zh-Hant']) {
      final value = translate[locale];
      if (value is List && value.isNotEmpty && value.first is String) {
        zh = value.first as String;
        break;
      }
    }
  }

  return BangumiDataItem(
    bgmId: bgmId,
    title: (raw['title'] as String?) ?? '',
    titleZh: zh,
    begin: begin,
    end: end,
    broadcastRule: raw['broadcast'] is String
        ? raw['broadcast'] as String
        : null,
    sites: kept,
  );
}
