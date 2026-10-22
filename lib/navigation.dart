import 'package:flutter/material.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Lets [RouteAware] pages learn they were covered or revealed again.
///
/// Restricted to [PageRoute] on purpose: dialogs and bottom sheets are
/// PopupRoutes, and sitting under one does not make a page hidden.
final rootRouteObserver = RouteObserver<PageRoute<void>>();

final _closedByExternalNavigation = <Route<Object?>>{};

/// 标记 [route] 为「外部导航时应当关闭」而不是被盖住。
///
/// 移植自 Predidit/Kazumi 提交 6485e353。
void closeOnExternalNavigation(Route<Object?> route) {
  _closedByExternalNavigation.add(route);
}

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
