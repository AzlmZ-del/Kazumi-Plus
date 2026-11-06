import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:kazumi/modules/bangumi/airing_slot.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/anime_schedule/bgm_anilist_map.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:path_provider/path_provider.dart';

/// 从 AniList 拉取整季放送排期。
///
/// 注意：mediaId_in 超过约 3 个 ID 会静默退化成全表查询，改用 GraphQL 别名。
class AiringScheduleService {
  AiringScheduleService._();

  static final AiringScheduleService instance = AiringScheduleService._();

  static const String _endpoint = 'https://graphql.anilist.co';

  /// 每批查询的番数上限。
  static const int _chunkSize = 50;

  /// 两次请求的最小间隔，避免 429。
  static const Duration _minInterval = Duration(milliseconds: 800);

  /// 单块请求最多重试次数，指数退避。
  static const int _maxRetry = 3;

  /// 排期缓存，key 是 AniList ID。
  final Map<int, SeasonSchedule> _schedules = {};

  /// 正在请求中的 ID，避免重复发请求。
  final Set<int> _inFlight = {};

  /// 缓存有新增时递增，供页面订阅重渲染。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 启动预热的进行中任务，供页面等待。
  Future<void>? _warmUpFuture;

  /// 磁盘缓存加载的进行中任务，避免并发重复读盘。
  Future<void>? _loadFuture;

  /// 磁盘缓存的写盘任务，串行化避免并发写坏文件。
  Future<void>? _saveFuture;

  /// 排期磁盘缓存的过期时长：超过这个时间的条目不再用于首帧渲染。
  ///
  /// 排期是「整季静态表」，理论上一个季度都有效；但番的档期偶尔改期，
  /// 留 14 天兜底，过期后照常走网络拿到新数据。
  static const Duration _cacheTtl = Duration(days: 14);

  DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);

  /// 已缓存的排期，只读。
  Map<int, SeasonSchedule> get schedules => Map.unmodifiable(_schedules);

  /// 查已缓存的排期，不触发网络请求。
  SeasonSchedule? cached(int anilistId) => _schedules[anilistId];

  /// 磁盘缓存文件：应用私有目录下的 anime_schedule/airing_schedules.json。
  Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    final target = Directory('${dir.path}/anime_schedule');
    if (!target.existsSync()) {
      await target.create(recursive: true);
    }
    return File('${target.path}/airing_schedules.json');
  }

  /// 从磁盘恢复排期（每个进程只读一次）。
  ///
  /// 冷启动时 `_schedules` 是空的，页面首帧的 `resolveCachedLatest()` 因此
  /// 拿不到任何数据，卡片先渲染成无 chip 的样子，等网络回包才「长出来」。
  /// 有了磁盘缓存，首帧就能带 chip。
  Future<void> ensureCacheLoaded() {
    final existing = _loadFuture;
    if (existing != null) return existing;
    return _loadFuture = _loadFromDisk();
  }

  Future<void> _loadFromDisk() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final version = decoded['version'];
      if (version != 1) return;
      final savedAtMs = decoded['savedAt'];
      if (savedAtMs is! int) return;
      final savedAt = DateTime.fromMillisecondsSinceEpoch(savedAtMs);
      if (DateTime.now().difference(savedAt) > _cacheTtl) {
        KazumiLogger().i('AiringScheduleService: 磁盘缓存已过期，忽略');
        return;
      }
      final schedules = decoded['schedules'];
      if (schedules is! Map<String, dynamic>) return;

      var restored = 0;
      schedules.forEach((key, value) {
        final anilistId = int.tryParse(key);
        if (anilistId == null || value is! Map<String, dynamic>) return;
        final rawSlots = value['slots'];
        if (rawSlots is! List) return;
        final slots = <AiringSlot>[];
        for (final item in rawSlots) {
          if (item is! Map) continue;
          final slot = AiringSlot.fromJson(item.cast<String, dynamic>());
          if (slot != null) slots.add(slot);
        }
        if (slots.isEmpty) return;
        slots.sort((a, b) => a.episode.compareTo(b.episode));
        _schedules[anilistId] = SeasonSchedule(
          anilistId: anilistId,
          slots: slots,
        );
        restored++;
      });
      if (restored > 0) {
        KazumiLogger().i('AiringScheduleService: 从磁盘恢复 $restored 部番排期');
        revision.value++;
      }
    } catch (error, stackTrace) {
      // 缓存坏了不该影响功能：忽略即可，后续网络拉取会重建。
      KazumiLogger().w('AiringScheduleService: 读取磁盘缓存失败',
          error: error, stackTrace: stackTrace);
    }
  }

  /// 把当前内存排期写回磁盘。串行化，避免并发写坏。
  Future<void> _persist() {
    final existing = _saveFuture;
    if (existing != null) {
      // 已有写任务在跑：排在它后面，保证最后一次写的是最新数据。
      return _saveFuture = existing.then((_) => _writeToDisk());
    }
    return _saveFuture = _writeToDisk();
  }

  Future<void> _writeToDisk() async {
    try {
      final payload = <String, dynamic>{
        'version': 1,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'schedules': {
          for (final entry in _schedules.entries)
            '${entry.key}': {
              'slots': [for (final slot in entry.value.slots) slot.toJson()],
            },
        },
      };
      final file = await _cacheFile();
      await file.writeAsString(jsonEncode(payload));
    } catch (error, stackTrace) {
      KazumiLogger().w('AiringScheduleService: 写磁盘缓存失败',
          error: error, stackTrace: stackTrace);
    }
  }

  /// 批量拉取排期，跳过已缓存的 ID。
  Future<int> fetch(List<int> anilistIds) async {
    final pending = anilistIds
        .where((id) => !_schedules.containsKey(id) && !_inFlight.contains(id))
        .toSet()
        .toList();
    if (pending.isEmpty) return 0;

    _inFlight.addAll(pending);
    var written = 0;
    try {
      for (var i = 0; i < pending.length; i += _chunkSize) {
        final chunk = pending.sublist(
          i,
          i + _chunkSize > pending.length ? pending.length : i + _chunkSize,
        );
        written += await _fetchChunk(chunk);
      }
    } finally {
      _inFlight.removeAll(pending);
    }
    return written;
  }

  Future<int> _fetchChunk(List<int> chunk, {int attempt = 0}) async {
    await _throttle();

    // 用 GraphQL 别名批量查，mediaId_in 超过几个 ID 会失效。
    final aliases = StringBuffer();
    for (var i = 0; i < chunk.length; i++) {
      aliases.write(' a$i: Media(id: ${chunk[i]}) {');
      aliases.write(' id airingSchedule(perPage: 50) {');
      aliases.write(' nodes { episode airingAt } } }');
    }
    final query = 'query {${aliases.toString()} }';

    try {
      final response = await DioFactory.pluginDio.post<dynamic>(
        _endpoint,
        data: {'query': query},
        options: Options(
          contentType: 'application/json',
          receiveTimeout: const Duration(seconds: 25),
        ),
      );
      final data = response.data;
      if (data is! Map) return 0;
      final payload = data['data'];
      if (payload is! Map) return 0;

      var written = 0;
      for (final entry in payload.entries) {
        final media = entry.value;
        if (media is! Map) continue;
        final mediaId = media['id'];
        final schedule = media['airingSchedule'];
        if (mediaId is! int || schedule is! Map) continue;
        final nodes = schedule['nodes'];
        if (nodes is! List) continue;

        final slots = <AiringSlot>[];
        for (final node in nodes) {
          if (node is! Map) continue;
          final episode = node['episode'];
          final airingAt = node['airingAt'];
          if (episode is! int || airingAt is! int) continue;
          slots.add(AiringSlot(
            episode: episode,
            airTime: airingTimeFromEpoch(airingAt),
          ));
        }
        if (slots.isEmpty) continue;
        slots.sort((a, b) => a.episode.compareTo(b.episode));
        _schedules[mediaId] = SeasonSchedule(anilistId: mediaId, slots: slots);
        written++;
      }
      // 有新数据就通知页面重渲染，并回写磁盘供下次冷启动直读。
      if (written > 0) {
        revision.value++;
        unawaited(_persist());
      }
      return written;
    } catch (error, stackTrace) {
      if (_isRetryable(error) && attempt < _maxRetry) {
        final delay = Duration(milliseconds: 1500 * (1 << attempt));
        KazumiLogger().w(
          'AiringScheduleService: chunk failed, retry ${attempt + 1}/$_maxRetry '
          'in ${delay.inMilliseconds}ms',
          error: error,
        );
        await Future.delayed(delay);
        // 重置节流基准，重试不必再等满间隔。
        _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);
        return _fetchChunk(chunk, attempt: attempt + 1);
      }
      KazumiLogger().w('AiringScheduleService: fetch failed',
          error: error, stackTrace: stackTrace);
      return 0;
    }
  }

  /// 限流、5xx、连接错误才值得重试。
  bool _isRetryable(Object error) {
    if (error is! DioException) return false;
    final status = error.response?.statusCode;
    if (status == 429) return true;
    if (status != null && status >= 500) return true;
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.connectionError =>
        true,
      _ => false,
    };
  }

  /// 把 Unix 秒转成本地时间。
  ///
  /// 单独抽出来是为了提醒调用方：这里必须标 `isUtc: true`，
  /// 否则会被当成本地时间解释，结果差一个时区。
  static DateTime airingTimeFromEpoch(int epochSeconds) {
    return DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true)
        .toLocal();
  }

  Future<void> _throttle() async {
    final wait = _minInterval - DateTime.now().difference(_lastRequest);
    if (wait > Duration.zero) await Future.delayed(wait);
    _lastRequest = DateTime.now();
  }

  /// 解析番单的展示信息：集号取最近一集，时分取整季众数。
  ///
  /// 不按星期列过滤——Bangumi 的 air_weekday 与 AniList 常对不上。
  Future<Map<int, AiringSlot>> resolveLatest(
    List<int> bgmIds, {
    bool insideWarmUp = false,
  }) async {
    if (bgmIds.isEmpty) return const {};

    // 先把磁盘缓存读进来：冷启动时内存是空的，不读盘就会白跑一轮网络。
    await ensureCacheLoaded();
    await BgmAniListMap.ensureLoaded();

    final idMap = <int, int>{};
    for (final bgmId in bgmIds) {
      final anilistId = BgmAniListMap.lookup(bgmId);
      if (anilistId != null) idMap[bgmId] = anilistId;
    }

    // 预热进行中时等它结束，否则 fetch 会被 _inFlight 判重返回 0。
    // insideWarmUp 要排除，否则会 await 包着自己的 Future 而永久挂死。
    if (!insideWarmUp) {
      final warming = _warmUpFuture;
      if (warming != null) {
        // 超时兜底，避免预热卡住时页面一直等。
        await warming.timeout(
          const Duration(seconds: 20),
          onTimeout: () {},
        );
      }
    }

    await fetch(idMap.values.toList());

    // 首轮失败的 ID 补一轮，只补一次。
    final stillMissing = idMap.values
        .where((id) => !_schedules.containsKey(id))
        .toList();
    if (stillMissing.isNotEmpty) {
      await fetch(stillMissing);
    }

    final now = DateTime.now();
    final result = <int, AiringSlot>{};
    idMap.forEach((bgmId, anilistId) {
      final schedule = _schedules[anilistId];
      if (schedule == null || schedule.isEmpty) return;
      final latest = schedule.nextUpcoming(now) ?? schedule.latestAired(now);
      if (latest == null) return;
      final typical = schedule.typicalAirTime(now);
      result[bgmId] = AiringSlot(
        episode: latest.episode,
        airTime: DateTime(
          latest.airTime.year,
          latest.airTime.month,
          latest.airTime.day,
          typical.hour,
          typical.minute,
        ),
      );
    });
    return result;
  }

  /// 同步版：只查已缓存的数据，不发请求。
  ///
  /// 供页面首帧使用，预热完成后进时间表即可带 chip，不出现「先空后补」。
  Map<int, AiringSlot> resolveCachedLatest(List<int> bgmIds) {
    if (bgmIds.isEmpty) return const {};
    final now = DateTime.now();
    final result = <int, AiringSlot>{};
    for (final bgmId in bgmIds) {
      final anilistId = BgmAniListMap.lookup(bgmId);
      if (anilistId == null) continue;
      final schedule = _schedules[anilistId];
      if (schedule == null || schedule.isEmpty) continue;
      final latest = schedule.nextUpcoming(now) ?? schedule.latestAired(now);
      if (latest == null) continue;
      final typical = schedule.typicalAirTime(now);
      result[bgmId] = AiringSlot(
        episode: latest.episode,
        airTime: DateTime(
          latest.airTime.year,
          latest.airTime.month,
          latest.airTime.day,
          typical.hour,
          typical.minute,
        ),
      );
    }
    return result;
  }

  /// 启动预热：提前把当前季排期拉进内存，进时间表时 chip 直接就位。
  ///
  /// 重复调用返回同一个 Future，页面侧可以 await 到真正结束。
  Future<void> warmUpOnStartup() {
    return _warmUpFuture ??= _doWarmUp().whenComplete(() {
      _warmUpFuture = null;
    });
  }

  Future<void> _doWarmUp() async {
    try {
      // 预热前先把磁盘缓存灌进内存，网络失败时页面首帧也能带 chip。
      await ensureCacheLoaded();
      final calendar = await BangumiApi.getCalendar();
      final bgmIds = <int>[
        for (final day in calendar) for (final item in day) item.id,
      ];
      if (bgmIds.isEmpty) return;
      // insideWarmUp 避免 await 到自己。
      await resolveLatest(bgmIds, insideWarmUp: true);
    } catch (error, stackTrace) {
      KazumiLogger().w('AiringScheduleService: warm up failed',
          error: error, stackTrace: stackTrace);
    }
  }
}
