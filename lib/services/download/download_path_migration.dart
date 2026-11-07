import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/file_system.dart';
import 'package:path/path.dart' as path;

/// iOS 在应用更新时可能搬动数据容器。下载文件会跟着搬，
/// 但 Hive 里存的绝对路径仍指向旧容器。
/// iOS 没有自定义下载目录，所以在任何播放、续传或删除之前，
/// 先把所有已开始的剧集指回当前默认目录。
Future<void> rebaseIosDownloadPaths(
  Box<DownloadRecord> downloads, {
  Future<String> Function() downloadDirectory = getDefaultDownloadDirectory,
}) async {
  try {
    await _rebaseDownloadPaths(downloads, await downloadDirectory());
  } catch (error, stackTrace) {
    // 即使迁移结果没法落盘（比如磁盘满了），现有 box 仍可继续使用。
    // 下次启动会基于已保存的记录重试一次。
    KazumiLogger().e(
      'DownloadStorage: iOS download path migration failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

Future<void> _rebaseDownloadPaths(
  Box<DownloadRecord> downloads,
  String downloadBase,
) async {
  var changed = false;
  for (final key in downloads.keys.toList()) {
    final record = downloads.get(key);
    if (record == null) continue;

    var recordChanged = false;
    for (final entry in record.episodes.entries) {
      final episode = entry.value;
      if (episode.downloadDirectory.isEmpty && episode.localM3u8Path.isEmpty) {
        continue;
      }

      final directory = path.join(
        downloadBase,
        '${record.bangumiId}_${record.pluginName}',
        '${entry.key}',
      );
      final videoPath = episode.localM3u8Path.isEmpty
          ? ''
          : path.join(directory, path.basename(episode.localM3u8Path));
      if (episode.downloadDirectory == directory &&
          episode.localM3u8Path == videoPath) {
        continue;
      }

      episode.downloadDirectory = directory;
      episode.localM3u8Path = videoPath;
      recordChanged = true;
    }

    if (recordChanged) {
      await downloads.put(key, record);
      changed = true;
    }
  }
  if (changed) await downloads.flush();
}
