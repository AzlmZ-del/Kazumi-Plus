import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/plugins/plugins.dart';

/// Route arguments for '/video/'. Entry points hand playback context over
/// through the route instead of pre-filling a shared controller, which lets
/// [VideoPageController] live and die with the route.
sealed class VideoPlaybackArgs {
  const VideoPlaybackArgs({required this.bangumiItem});

  final BangumiItem bangumiItem;
}

class OnlineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OnlineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.plugin,
    required this.title,
    required this.src,
    required this.roads,
    this.initialEpisode = 1,
    this.initialRoad = 0,
    this.pinInitialEpisode = false,
  });

  final Plugin plugin;
  final String title;
  final String src;
  final List<Road> roads;

  /// 1 起的集数，供规则测试页「测试播放」直接跳到指定集。
  final int initialEpisode;

  /// 0 起的线路序号。
  final int initialRoad;

  /// 为 true 时 [initialEpisode]/[initialRoad] 是硬指定，不再被观看记录覆盖。
  /// 普通入口走默认值，仍然按历史记录续播。
  final bool pinInitialEpisode;
}

class OfflineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OfflineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.pluginName,
    required this.episodeNumber,
    required this.road,
    required this.downloadedEpisodes,
  });

  final String pluginName;
  final int episodeNumber;
  final int road;
  final List<DownloadEpisode> downloadedEpisodes;
}
