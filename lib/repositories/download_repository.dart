import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/logging/logger.dart';

abstract class IDownloadRepository {
  /// 记录或剧集状态落盘时发出通知。进度 tick 只留在内存里，
  /// 因此不会触发通知。
  Stream<void> get changes;

  List<DownloadRecord> getAllRecords();
  DownloadRecord? getRecord(String key);
  Future<void> putRecord(DownloadRecord record);
  Future<void> deleteRecord(String key);
  Future<void> updateEpisode(
      String recordKey, int episodeNumber, DownloadEpisode episode);
  Future<void> deleteEpisode(String recordKey, int episodeNumber);
  bool getForceAdBlocker();

  /// 取指定番剧的下载记录。
  DownloadRecord? getRecordByBangumiId(int bangumiId, String pluginName);

  /// 取指定集数的下载信息。
  DownloadEpisode? getEpisode(
      int bangumiId, String pluginName, int episodeNumber);

  /// 取所有已完成下载的集数。
  List<DownloadEpisode> getCompletedEpisodes(int bangumiId, String pluginName);

  /// 按集数页面 URL 查下载记录，URL 为空时返回 null（兼容旧数据）。
  DownloadEpisode? getEpisodeByUrl(
      int bangumiId, String pluginName, String episodePageUrl);
}

class DownloadRepository implements IDownloadRepository {
  final _downloadsBox = GStorage.downloads;

  @override
  Stream<void> get changes => _downloadsBox.watch();

  @override
  List<DownloadRecord> getAllRecords() {
    final List<DownloadRecord> result = [];
    try {
      for (final key in _downloadsBox.keys) {
        try {
          final record = _downloadsBox.get(key);
          if (record != null) {
            // 把内存里的进度合并进记录。
            final cachedEpisodes = _progressCache[key as String];
            if (cachedEpisodes != null) {
              for (final entry in cachedEpisodes.entries) {
                record.episodes[entry.key] = entry.value;
              }
            }
            result.add(record);
          }
        } catch (e) {
          // 单条记录读取失败，跳过该记录并记录日志
          KazumiLogger().w(
              'DownloadRepository: failed to read record key=$key, skipping',
              error: e);
        }
      }
    } catch (e) {
      KazumiLogger().w('DownloadRepository: get all records failed', error: e);
    }
    return result;
  }

  @override
  DownloadRecord? getRecord(String key) {
    try {
      final record = _downloadsBox.get(key);
      if (record != null) {
        // 把内存里的进度合并进记录。
        final cachedEpisodes = _progressCache[key];
        if (cachedEpisodes != null) {
          for (final entry in cachedEpisodes.entries) {
            record.episodes[entry.key] = entry.value;
          }
        }
      }
      return record;
    } catch (e) {
      KazumiLogger()
          .w('DownloadRepository: get record failed. key=$key', error: e);
      return null;
    }
  }

  @override
  Future<void> putRecord(DownloadRecord record) async {
    try {
      await _downloadsBox.put(record.key, record);
      await _downloadsBox.flush();
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'DownloadRepository: put record failed. key=${record.key}',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Future<void> deleteRecord(String key) async {
    try {
      await _downloadsBox.delete(key);
      await _downloadsBox.flush();
      _progressCache.remove(key);
      _lastPersistedStatus.removeWhere((k, v) => k.startsWith('${key}_'));
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'DownloadRepository: delete record failed. key=$key',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 记住上次落盘的状态，避免不必要的写入。
  final Map<String, int> _lastPersistedStatus = {};

  /// 进度更新的内存缓存（状态不变就不落盘）。
  final Map<String, Map<int, DownloadEpisode>> _progressCache = {};

  @override
  Future<void> updateEpisode(
      String recordKey, int episodeNumber, DownloadEpisode episode) async {
    try {
      // 更新内存缓存。
      _progressCache.putIfAbsent(recordKey, () => {});
      _progressCache[recordKey]![episodeNumber] = episode;

      // 只在状态变化时写 Hive（不是每次进度更新都写）
      // 这能大幅减少磁盘 I/O，也避免崩溃时把数据写坏。
      final statusKey = '${recordKey}_$episodeNumber';
      final lastStatus = _lastPersistedStatus[statusKey];
      final shouldPersist = lastStatus != episode.status;

      if (shouldPersist) {
        final record = _downloadsBox.get(recordKey);
        if (record == null) return;
        record.episodes[episodeNumber] = episode;
        await _downloadsBox.put(recordKey, record);
        await _downloadsBox.flush();
        _lastPersistedStatus[statusKey] = episode.status;
      }
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'DownloadRepository: update episode failed. key=$recordKey, ep=$episodeNumber',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  bool getForceAdBlocker() {
    return GStorage.getSetting(SettingsKeys.forceAdBlocker);
  }

  @override
  Future<void> deleteEpisode(String recordKey, int episodeNumber) async {
    try {
      final record = _downloadsBox.get(recordKey);
      if (record == null) return;
      record.episodes.remove(episodeNumber);
      if (record.episodes.isEmpty) {
        await _downloadsBox.delete(recordKey);
        _progressCache.remove(recordKey);
        _lastPersistedStatus
            .removeWhere((k, v) => k.startsWith('${recordKey}_'));
      } else {
        await _downloadsBox.put(recordKey, record);
        _progressCache[recordKey]?.remove(episodeNumber);
        _lastPersistedStatus.remove('${recordKey}_$episodeNumber');
      }
      await _downloadsBox.flush();
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'DownloadRepository: delete episode failed. key=$recordKey, ep=$episodeNumber',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  DownloadRecord? getRecordByBangumiId(int bangumiId, String pluginName) {
    final key = '${pluginName}_$bangumiId';
    return getRecord(key);
  }

  @override
  DownloadEpisode? getEpisode(
      int bangumiId, String pluginName, int episodeNumber) {
    final record = getRecordByBangumiId(bangumiId, pluginName);
    return record?.episodes[episodeNumber];
  }

  @override
  List<DownloadEpisode> getCompletedEpisodes(int bangumiId, String pluginName) {
    final record = getRecordByBangumiId(bangumiId, pluginName);
    if (record == null) return [];

    return record.episodes.values
        .where((e) => e.status == DownloadStatus.completed)
        .toList()
      ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
  }

  @override
  DownloadEpisode? getEpisodeByUrl(
      int bangumiId, String pluginName, String episodePageUrl) {
    if (episodePageUrl.isEmpty) return null;
    final record = getRecordByBangumiId(bangumiId, pluginName);
    if (record == null) return null;
    for (final episode in record.episodes.values) {
      if (episode.episodePageUrl == episodePageUrl) {
        return episode;
      }
    }
    return null;
  }
}
