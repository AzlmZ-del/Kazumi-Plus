import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/history/history_module.dart';

final class WatchStats {
  const WatchStats({
    this.watchedEpisodeCount = 0,
    this.watchedBangumiCount = 0,
    this.downloadTaskCount = 0,
  });

  final int watchedEpisodeCount;
  final int watchedBangumiCount;
  final int downloadTaskCount;

  @override
  bool operator ==(Object other) =>
      other is WatchStats &&
      other.watchedEpisodeCount == watchedEpisodeCount &&
      other.watchedBangumiCount == watchedBangumiCount &&
      other.downloadTaskCount == downloadTaskCount;

  @override
  int get hashCode => Object.hash(
        watchedEpisodeCount,
        watchedBangumiCount,
        downloadTaskCount,
      );

  factory WatchStats.from({
    required List<History> histories,
    required List<DownloadRecord> downloadRecords,
  }) {
    // 按 (番剧 ID, 集号) 去重：同一集可能因多条规则、在线与离线记录各出现一次。
    final watchedEpisodes = <(int, int)>{};
    final watchedBangumiIds = <int>{};
    for (final history in histories) {
      if (history.progresses.isEmpty) continue;
      final bangumiId = history.bangumiItem.id;
      watchedBangumiIds.add(bangumiId);
      for (final episode in history.progresses.keys) {
        watchedEpisodes.add((bangumiId, episode));
      }
    }

    return WatchStats(
      watchedEpisodeCount: watchedEpisodes.length,
      watchedBangumiCount: watchedBangumiIds.length,
      // 所有下载任务都计数，不看状态——失败与暂停的也算。
      downloadTaskCount: downloadRecords.fold(
        0,
        (count, record) => count + record.episodes.length,
      ),
    );
  }
}
