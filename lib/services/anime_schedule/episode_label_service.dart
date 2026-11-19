import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:path_provider/path_provider.dart';

/// 单集文案：`第 7 话 · 潜入黑暗斗技场`。
///
/// 集数与集名都取自 Bangumi 的章节接口，与放送时刻（bangumi-data）是两套
/// 独立来源，日期未必同日，调用方要用 [labelFor] 做多时区回退匹配。
///
/// 数据落盘：章节文案很少变，冷启动必须能立刻显示，否则整列先出「第 N 集」
/// 兜底、再逐条替换成「第 N 话 · 标题」，看上去就是严重滞后。
class EpisodeLabelService {
  EpisodeLabelService._();

  static final EpisodeLabelService instance = EpisodeLabelService._();

  /// 内存有效期：同一次运行内不必反复查。
  static const Duration _ttl = Duration(minutes: 30);

  /// 磁盘有效期：隔夜的章节文案基本不变，一天足够。
  static const Duration _diskTtl = Duration(hours: 24);

  /// 同时最多 4 个在途请求。原来串行 2 个，一天 11 部要等 5 秒以上。
  static const int _maxConcurrent = 4;

  final Map<int, _LabelCache> _cache = {};
  final Map<int, Future<Map<String, String>?>> _inFlight = {};

  /// 并发闸门：先到先得的等待队列，取代原来每 120ms 轮询一次的忙等。
  final List<Completer<void>> _queue = [];
  int _running = 0;

  Future<void>? _loading;
  Future<void>? _saving;
  bool _dirty = false;

  /// 只读本地缓存，不联网；首次调用返回后 [cachedLabels] 才有内容。
  Future<void> ensureLoaded() {
    return _loading ??= _loadFromDisk();
  }

  /// 已缓存条目的文案，供页面首帧直接渲染。
  Map<int, Map<String, String>?> cachedLabels(Iterable<int> ids) {
    final result = <int, Map<String, String>?>{};
    for (final id in ids) {
      final entry = _cache[id];
      if (entry != null) result[id] = entry.labels;
    }
    return result;
  }

  Future<void> _loadFromDisk() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final now = DateTime.now();
      decoded.forEach((key, value) {
        final id = int.tryParse('$key');
        if (id == null || value is! Map) return;
        final at = value['at'];
        final labels = value['labels'];
        if (at is! int || labels is! Map) return;
        final fetchedAt = DateTime.fromMillisecondsSinceEpoch(at);
        if (now.difference(fetchedAt) > _diskTtl) return;
        _cache[id] = _LabelCache(fetchedAt, {
          for (final entry in labels.entries)
            if (entry.value is String) '${entry.key}': entry.value as String,
        });
      });
      if (_cache.isNotEmpty) {
        KazumiLogger().i('EpisodeLabelService: 从磁盘恢复 ${_cache.length} 条章节文案');
      }
    } catch (error, stackTrace) {
      KazumiLogger().w(
        'EpisodeLabelService: 读取磁盘缓存失败',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _loading = null;
    }
  }

  /// 取某条目的「日期 → 单集文案」映射；失败返回 null（不是空表）。
  Future<Map<String, String>?> load(int bgmId) {
    final cached = _cache[bgmId];
    if (cached != null && DateTime.now().difference(cached.at) < _ttl) {
      return Future.value(cached.labels);
    }
    return _inFlight[bgmId] ??= _fetch(bgmId).whenComplete(() {
      _inFlight.remove(bgmId);
    });
  }

  Future<Map<String, String>?> _fetch(int bgmId) async {
    await _acquire();
    try {
      final episodes = await BangumiApi.getBangumiEpisodesByID(
        bgmId,
        throwOnError: true,
      );
      final labels = <String, StringBuffer>{};
      for (final episode in episodes) {
        final date = episode.airDate;
        if (date.isEmpty) continue;
        final number = episode.episode;
        final parts = <String>[];
        if (number > 0) {
          parts.add('第 $number 话');
        }
        final title = episode.displayTitle();
        // 章节标题常常就是占位符（`第06話`），与集数拼接后重复。
        if (title.isNotEmpty && !_isPlaceholder(title, number)) {
          parts.add(title);
        }
        if (parts.isEmpty) continue;
        final buffer = labels.putIfAbsent(date, StringBuffer.new);
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(parts.join(' · '));
      }
      final result = {
        for (final entry in labels.entries) entry.key: entry.value.toString(),
      };
      _cache[bgmId] = _LabelCache(DateTime.now(), result);
      _dirty = true;
      unawaited(_persist());
      return result;
    } catch (error) {
      KazumiLogger().w(
        'EpisodeLabelService: 拉取章节失败 bgmId=$bgmId',
        error: error,
      );
      return null;
    } finally {
      _release();
    }
  }

  /// 上游不少章节没有正式标题，只有 `第06話` / `EP06` / `08` 这类占位符。
  ///
  /// 截图里 `第 8 话 · 08` 就是没过滤掉的纯数字标题，与集数重复。
  static bool _isPlaceholder(String title, num number) {
    final compact = title.replaceAll(RegExp(r'\s'), '');
    final digits = number == number.round() ? '${number.toInt()}' : '$number';
    final padded = digits.padLeft(2, '0');
    final lower = compact.toLowerCase();
    return compact == '第$digits話' ||
        compact == '第$digits话' ||
        compact == '第$digits集' ||
        lower == 'ep$digits' ||
        lower == 'ep.$digits' ||
        // 纯数字标题：`8` / `08` / `008` 都视为与集数重复。
        (RegExp(r'^\d+$').hasMatch(compact) &&
            (int.tryParse(compact) == number ||
                compact == padded ||
                int.tryParse(compact) == int.tryParse(digits)));
  }

  Future<void> _acquire() {
    if (_running < _maxConcurrent) {
      _running++;
      return Future.value();
    }
    final completer = Completer<void>();
    _queue.add(completer);
    return completer.future;
  }

  void _release() {
    if (_queue.isNotEmpty) {
      // 直接把名额转交给下一个等待者，不减计数。
      _queue.removeAt(0).complete();
      return;
    }
    _running--;
  }

  /// 串行化落盘，避免并发写坏文件。
  Future<void> _persist() {
    final existing = _saving;
    if (existing != null) return _saving = existing.then((_) => _write());
    return _saving = _write();
  }

  Future<void> _write() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      final payload = {
        for (final entry in _cache.entries)
          '${entry.key}': {
            'at': entry.value.at.millisecondsSinceEpoch,
            'labels': entry.value.labels,
          },
      };
      final file = await _cacheFile();
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(payload), flush: true);
      await temp.rename(file.path);
    } catch (error, stackTrace) {
      KazumiLogger().w(
        'EpisodeLabelService: 写入磁盘缓存失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    final target = Directory('${dir.path}/anime_schedule');
    if (!target.existsSync()) {
      await target.create(recursive: true);
    }
    return File('${target.path}/episode_labels.json');
  }

  /// 用放送时刻找当天的单集文案。
  ///
  /// 上游 airdate 的时区约定并不统一（实测多数按 UTC 日、少量按 JST），
  /// 这里按「UTC → +9 → +8」依次试探，命中即用。
  static String? labelFor(Map<String, String>? labels, DateTime? airTime) {
    if (labels == null || labels.isEmpty || airTime == null) return null;
    final utc = airTime.toUtc();
    for (final offset in const [0, 9, 8]) {
      final shifted = utc.add(Duration(hours: offset));
      final key = _dateKey(shifted);
      final label = labels[key];
      if (label != null && label.isNotEmpty) return label;
    }
    return null;
  }

  static String _dateKey(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }
}

class _LabelCache {
  const _LabelCache(this.at, this.labels);

  final DateTime at;
  final Map<String, String> labels;
}

/// 时间表页面的单集文案状态。
///
/// 从页面里抽出来是为了能单测：之前「加载完只 setState、忘了写回返回值」
/// 这个 bug 一路发到了真机，因为页面级的这段逻辑完全没被覆盖。
class EpisodeLabelsStore {
  EpisodeLabelsStore({
    Future<Map<String, String>?> Function(int bgmId)? loader,
    VoidCallback? onChanged,
  }) : _loader = loader ?? EpisodeLabelService.instance.load,
       _onChanged = onChanged;

  final Future<Map<String, String>?> Function(int bgmId) _loader;

  /// 任何一次写入后回调，页面用它触发重建。
  final VoidCallback? _onChanged;

  Map<int, Map<String, String>?> _labels = const {};
  final Set<int> _loading = <int>{};

  Map<int, Map<String, String>?> get labels => _labels;

  /// 已落盘的文案直接并进来，不发请求。
  void merge(Map<int, Map<String, String>?> cached) {
    if (cached.isEmpty) return;
    _labels = {..._labels, ...cached};
    _onChanged?.call();
  }

  /// 对尚未加载的条目并发发起请求，各自回来各自写入。
  ///
  /// 返回一个能等到全部完成的 Future，测试与调用方都可以 await。
  Future<void> loadAll(Iterable<int> ids) {
    final pending = ids
        .where((id) => !_labels.containsKey(id))
        .where(_loading.add)
        .toList();
    if (pending.isEmpty) return Future.value();
    return Future.wait(
      pending.map((id) async {
        try {
          final labels = await _loader(id);
          // 失败（null）不写入：否则 containsKey 会当成已加载，永远不重试。
          if (labels != null) {
            _labels = {..._labels, id: labels};
            _onChanged?.call();
          }
        } finally {
          _loading.remove(id);
        }
      }),
    );
  }
}
