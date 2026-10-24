import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/async_session.dart';
import 'package:kazumi/utils/device.dart';
import 'package:window_manager/window_manager.dart';

import 'kazumi_deep_link.dart';

/// 接收 kazumi:// 深链并跳转到对应页面。
///
/// 移植自 Predidit/Kazumi 提交 6485e353（feat: support anime deep links #2736）
/// 与 b935bd44（feat(linux): deeplink #2745）。
class AppDeepLinks {
  static final AppDeepLinks _instance = AppDeepLinks._internal();
  factory AppDeepLinks() => _instance;
  AppDeepLinks._internal();

  StreamSubscription<Uri>? _subscription;
  final _sessions = AsyncSessionOwner();
  final _dialogs = KazumiDialogController();
  final _ready = Completer<void>();

  void start() {
    if (_subscription != null) return;
    _subscription = AppLinks().uriLinkStream.listen(
      _receive,
      onError: (Object error) {
        KazumiLogger().w('Deep link: failed to receive', error: error);
      },
    );
  }

  /// 首页渲染完成后调用：早于此的跳转会被启动流程清掉。
  void markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  void _receive(Uri uri) {
    final link = KazumiDeepLink.parse(uri);
    if (link == null) return;
    final session = _sessions.begin();
    _dialogs.cancel();
    unawaited(_open(link, session).catchError((Object error) {
      if (session.isStale) return;
      KazumiLogger().w('Deep link: failed to open', error: error);
      KazumiDialog.showToast(message: '无法打开链接');
    }));
  }

  Future<void> _open(KazumiDeepLink link, AsyncSession session) async {
    await _ready.future;
    if (session.isStale) return;
    // Windows：由转发的实例唤起（见 windows/runner/main.cpp）；移动端由系统唤起。
    if (Platform.isMacOS) {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    }
    switch (link) {
      case BangumiDeepLink(:final id):
        await _dialogs.run((task) async {
          final item = await task.loading(
            message: '正在获取番剧信息',
            barrierDismissible: isDesktop(),
            action: () => BangumiApi.getBangumiInfoByID(id),
          );
          if (item == null) {
            KazumiDialog.showToast(message: '无法获取番剧详情');
            return;
          }
          _push(session, '/info/', arguments: item);
        });
      case SearchDeepLink(:final query):
        final route = Uri(path: '/search/', queryParameters: {'query': query});
        _push(session, route.toString());
    }
  }

  void _push(AsyncSession session, String path, {Object? arguments}) {
    final navigator = rootNavigatorKey.currentState;
    if (session.isStale || navigator == null || !navigator.mounted) return;
    if (!popForExternalNavigation(navigator)) {
      KazumiDialog.showToast(message: '当前操作进行中，未打开链接');
      return;
    }
    if (GStorage.getSetting(SettingsKeys.deepLinkReturnHome)) {
      _resetToStartPage(navigator);
    }
    unawaited(navigator.context.pushNamed(path, arguments: arguments));
  }

  /// 深链默认压在原来那一页之上，返回就回到原页面。开启「深链返回首页」后
  /// 先把根栈换成启动页，再压深链目标，返回便落在首页标签。
  ///
  /// 代价是当前标签位置与栈内页面都会重建，因此该行为默认关闭。
  void _resetToStartPage(NavigatorState navigator) {
    final startPage = GStorage.getSetting(SettingsKeys.defaultStartupPage);
    if (startPage.isEmpty || startPage == '/') return;
    try {
      navigator.context.navigate(startPage);
    } catch (error) {
      KazumiLogger().w('Deep link: failed to reset to start page', error: error);
    }
  }
}
