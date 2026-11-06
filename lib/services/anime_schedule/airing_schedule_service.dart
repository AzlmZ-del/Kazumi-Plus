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

  /// mediaId_in 超过约 3 个 ID 会静默退化成全表查询，故用 GraphQL 别名。
class AiringScheduleService {
  AiringScheduleService._();

  static final AiringScheduleService instance = AiringScheduleService._();

  static const String _endpoint = 'https://graphql.anilist.co';

  static const int _chunkSize = 50;

  /// 避免 429。
  static const Duration _minInterval = Duration(milliseconds: 800);

  static const int _maxRetry = 3;

  final Map<int, SeasonSchedule> _schedules = {};

  final Set<int> _inFlight = {};

  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Future<void>? _warmUpFuture;

  Future<void>? _loadFuture;

  Future<void>? _saveFuture;

  /// 档期偶尔改期，14 天兜底。
  static const Duration _cacheTtl = Duration(days: 14);

  DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);

  Map<int, SeasonSchedule> get schedules => Map.unmodifiable(_schedules);

  SeasonSchedule? cached(int anilistId) => _schedules[anilistId];

  Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    final target = Directory('${dir.path}/anime_schedule');
    if (!target.existsSync()) {
      await target.create(recursive: true);
    }
    return File('${target.path}/airing_schedules.json');
  }

  /// 每个进程只读一次；冷启动靠它让首帧就带 chip。
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
      KazumiLogger().w('AiringScheduleService: 读取磁盘缓存失败',
          error: error, stackTrace: stackTrace);
    }
  }

  /// 串行化，避免并发写坏文件。
  Future<void> _persist() {
    final existing = _saveFuture;
    if (existing != null) {
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

  /// 必须 isUtc 再 toLocal，否则差一个时区。
  static DateTime airingTimeFromEpoch(int epochSeconds) {
    return DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true)
        .toLocal();
  }

  Future<void> _throttle() async {
    final wait = _minInterval - DateTime.now().difference(_lastRequest);
    if (wait > Duration.zero) await Future.delayed(wait);
    _lastRequest = DateTime.now();
  }

  /// 不按星期列过滤：Bangumi 的 air_weekday 与 AniList 常对不上。
  Future<Map<int, AiringSlot>> resolveLatest(
    List<int> bgmIds, {
    bool insideWarmUp = false,
  }) async {
    if (bgmIds.isEmpty) return const {};

    await ensureCacheLoaded();
    await BgmAniListMap.ensureLoaded();

    final idMap = <int, int>{};
    for (final bgmId in bgmIds) {
      final anilistId = BgmAniListMap.lookup(bgmId);
      if (anilistId != null) idMap[bgmId] = anilistId;
    }

    // insideWarmUp 必须排除，否则 await 到自己会永久挂死。
    if (!insideWarmUp) {
      final warming = _warmUpFuture;
      if (warming != null) {
        await warming.timeout(
          const Duration(seconds: 20),
          onTimeout: () {},
        );
      }
    }

    await fetch(idMap.values.toList());

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

  /// 只查已缓存数据，不发请求；供页面首帧用。
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

  /// 重复调用返回同一个 Future。
  Future<void> warmUpOnStartup() {
    return _warmUpFuture ??= _doWarmUp().whenComplete(() {
      _warmUpFuture = null;
    });
  }

  Future<void> _doWarmUp() async {
    try {
      await ensureCacheLoaded();
      final calendar = await BangumiApi.getCalendar();
      final bgmIds = <int>[
        for (final day in calendar) for (final item in day) item.id,
      ];
      if (bgmIds.isEmpty) return;
      await resolveLatest(bgmIds, insideWarmUp: true);
    } catch (error, stackTrace) {
      KazumiLogger().w('AiringScheduleService: warm up failed',
          error: error, stackTrace: stackTrace);
    }
  }
}
