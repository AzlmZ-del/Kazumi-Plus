import 'package:flutter/material.dart';

/// 所在的页面子树是否被其他页面盖住。
///
/// 由持有该路由的页面发布，长期存活的子组件据此在隐藏时停掉后台工作，
/// 不必自己去翻导航栈。
class RouteVisibility extends InheritedWidget {
  const RouteVisibility({
    super.key,
    required this.isCovered,
    required super.child,
  });

  final bool isCovered;

  /// 订阅这个状态；只有状态翻转时才通知依赖方。
  static bool isCoveredOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<RouteVisibility>()
            ?.isCovered ??
        false;
  }

  @override
  bool updateShouldNotify(RouteVisibility oldWidget) =>
      isCovered != oldWidget.isCovered;
}
