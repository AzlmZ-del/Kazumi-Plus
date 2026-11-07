import 'package:flutter/material.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// 让 [RouteAware] 页面感知自己被盖住或重新露出。
///
/// 刻意限定 [PageRoute]：对话框与底部弹层都是 PopupRoute，
/// 页面被它们盖住并不算「隐藏」。
final rootRouteObserver = RouteObserver<PageRoute<void>>();

final _closedByExternalNavigation = <Route<Object?>>{};

/// 标记 [route] 为「外部导航时应当关闭」而不是被盖住。
///
/// 移植自 Predidit/Kazumi 提交 6485e353。
void closeOnExternalNavigation(Route<Object?> route) {
  _closedByExternalNavigation.add(route);
}

/// 清除标记。路由销毁后要调一次，否则这个全局 Set 会一直持有已失效的
/// Route 对象，越积越多。
void clearExternalNavigationMark(Route<Object?> route) {
  _closedByExternalNavigation.remove(route);
}

/// 像按返回键那样弹掉被标记的路由及其上方的所有页面，让 [PopScope]
/// 与本地历史记录正常回卷。若有路由拒绝弹出则返回 false。
bool popForExternalNavigation(NavigatorState navigator) {
  bool hasMarkedRoute() => _closedByExternalNavigation
      .any((route) => route.isActive && route.navigator == navigator);

  var vetoed = false;
  navigator.popUntil((current) {
    if (!hasMarkedRoute()) return true;
    vetoed = current.popDisposition == RoutePopDisposition.doNotPop;
    return vetoed;
  });
  return !vetoed;
}
