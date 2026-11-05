import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:kazumi/modules/bangumi/airing_slot.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/anime_schedule/bgm_anilist_map.dart';
import 'package:kazumi/services/logging/logger.dart';

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

  DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);

  /// 已缓存的排期，只读。
  Map<int, SeasonSchedule> get schedules => Map.unmodifiable(_schedules);

  /// 查已缓存的排期，不触发网络请求。
  SeasonSchedule? cached(int anilistId) => _schedules[anilistId];

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
      // 有新数据就通知页面重渲染。
      if (written > 0) revision.value++;
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
