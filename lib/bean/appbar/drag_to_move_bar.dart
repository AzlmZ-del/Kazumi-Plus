import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/utils/device.dart';

/// 隐藏标题栏之后，把本组件放进界面就能拖动窗口位置。
class DragToMoveArea extends StatelessWidget {
  const DragToMoveArea({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => (isDesktop()) ? windowManager.startDragging() : null,
      child: child,
    );
  }
}
