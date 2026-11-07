import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/services/platform/display_mode_service.dart';

/// 放在 Scaffold 之上，测量窗口尺寸时就不含键盘占用的高度。
class VideoSystemBars extends StatefulWidget {
  const VideoSystemBars({
    super.key,
    required this.fullscreen,
    required this.isPip,
    required this.child,
  });

  final bool fullscreen;
  final bool isPip;
  final Widget child;

  @override
  State<VideoSystemBars> createState() => _VideoSystemBarsState();
}

class _VideoSystemBarsState extends State<VideoSystemBars> with RouteAware {
  PageRoute<void>? _route;
  bool _visible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void> && !identical(route, _route)) {
      rootRouteObserver.unsubscribe(this);
      _route = route;
      _visible = route.isCurrent;
      rootRouteObserver.subscribe(this, route);
    }
    _sync();
  }

  @override
  void didUpdateWidget(covariant VideoSystemBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didPushNext() => _setVisible(false);

  @override
  void didPopNext() => _setVisible(true);

  @override
  void didPop() => _setVisible(false);

  void _setVisible(bool visible) {
    _visible = visible;
    _sync();
  }

  void _sync() {
    if (!_visible || _route?.isActive == false) {
      unawaited(DisplayModeService.releaseSystemBars(this));
    } else if (!widget.isPip) {
      // 画中画在原始尺寸恢复之前，一直保持「整窗」这个偏好。
      final landscape =
          MediaQuery.orientationOf(context) == Orientation.landscape;
      unawaited(DisplayModeService.setSystemBarsHidden(
        owner: this,
        hidden: widget.fullscreen || landscape,
      ));
    }
  }

  @override
  void dispose() {
    rootRouteObserver.unsubscribe(this);
    unawaited(DisplayModeService.releaseSystemBars(this));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
