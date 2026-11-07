import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';
import 'package:kazumi/pages/timeline/timeline_controller.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/repositories/collect_repository.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/repositories/danmaku_shield_repository.dart';
import 'package:kazumi/repositories/history_repository.dart';
import 'package:kazumi/repositories/search_history_repository.dart';
import 'package:kazumi/services/backup/local_backup_service.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/player/history_playback_service.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/sync/danmaku_shield_sync_service.dart';
import 'package:kazumi/services/sync/webdav.dart';

/// 应用级数据与跨功能协调器，归根模块持有。
///
/// 本模块刻意不带 path，注册的东西与整个应用同生命周期。
/// 页面内与功能局部状态应放进路由的 `provide` 回调，或带 path 的模块。
final coreModule = createModule(
  register: (c) {
    c
      // 仓库层。
      ..addSingleton<ICollectRepository>(CollectRepository.new)
      ..addSingleton<ISearchHistoryRepository>(SearchHistoryRepository.new)
      ..addSingleton<ICollectCrudRepository>(CollectCrudRepository.new)
      ..addSingleton<IHistoryRepository>(HistoryRepository.new)
      ..addSingleton<IDownloadRepository>(DownloadRepository.new)
      ..addSingleton<IDanmakuShieldRepository>(DanmakuShieldRepository.new)
      // 服务层。
      ..addSingleton<IDownloadManager>(DownloadManager.new)
      ..addSingleton<AudioController>(AudioController.new)
      ..addSingleton<HistoryPlaybackService>(HistoryPlaybackService.new)
      ..addSingleton<ShaderAssetService>(ShaderAssetService.new)
      ..addSingleton<WebDav>(WebDav.new)
      ..addSingleton<LocalBackupService>(LocalBackupService.new)
      ..addSingleton<DanmakuShieldSyncService>(DanmakuShieldSyncService.new)
      // 跨功能状态与协调器。
      ..addSingleton<PluginsController>(PluginsController.new)
      ..addSingleton<CollectController>(CollectController.new)
      ..addSingleton<HistoryController>(HistoryController.new)
      ..addSingleton<MyController>(MyController.new)
      ..addSingleton<DownloadController>(DownloadController.new)
      // 比外壳活得更久的 Tab 内容状态。深链会替换根栈，从而销毁 `/tab` 模块；
      // 把这两个控制器放在这里，推荐与时间表重新打开时才能保留数据与滚动位置。
      ..addSingleton<PopularController>(PopularController.new)
      ..addSingleton<TimelineController>(TimelineController.new);
  },
);
