import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kazumi/bean/widget/side_panel_transition.dart';

class VideoSidePanel extends StatefulWidget {
  const VideoSidePanel({
    super.key,
    required this.fullscreen,
    required this.child,
    this.disableAnimations = false,
    this.onOpened,
    this.onClosed,
  });

  final bool fullscreen;
  final bool disableAnimations;
  final Widget child;
  final VoidCallback? onOpened;
  final VoidCallback? onClosed;

  @override
  State<VideoSidePanel> createState() => VideoSidePanelState();
}

class VideoSidePanelState extends State<VideoSidePanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: SidePanelTransition.duration,
  );
  late final Animation<double> _opacity =
      _animation.drive(CurveTween(curve: Curves.easeIn));

  bool get _isOpening =>
      _animation.status == AnimationStatus.forward ||
      _animation.status == AnimationStatus.completed;

  void toggle() {
    if (_isOpening) {
      close();
    } else {
      if (widget.disableAnimations) {
        _animation.value = 1;
      } else {
        _animation.forward();
      }
      widget.onOpened?.call();
    }
  }

  void close() {
    if (widget.disableAnimations) {
      _animation.value = 0;
    } else {
      _animation.reverse();
    }
    widget.onClosed?.call();
  }

  @override
  void didUpdateWidget(VideoSidePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 渲染新模式前先重置，避免侧栏闪一下。
    if (oldWidget.fullscreen != widget.fullscreen) _animation.value = 0;
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => AnimatedBuilder(
          animation: _animation,
          builder: (context, child) {
            if (_animation.isDismissed) return const SizedBox.shrink();
            return Stack(
              alignment: Alignment.centerRight,
              children: [
                FadeTransition(
                  opacity: _opacity,
                  child: GestureDetector(
                    onTap: close,
                    child: SizedBox.expand(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              Colors.black.withValues(alpha: 0.5),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SidePanelTransition(animation: _animation, child: child!),
              ],
            );
          },
          child: SizedBox(
            // 面板外留出空间，供点击关闭。
            width: math.min(constraints.maxWidth * 0.9,
                (constraints.maxWidth / 3).clamp(320.0, 420.0)),
            height: constraints.maxHeight,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadiusDirectional.only(
                topStart: Radius.circular(28),
                bottomStart: Radius.circular(28),
              ),
              clipBehavior: Clip.antiAlias,
              // 整个浮层都要吃掉被隐藏状态栏留下的内边距。
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                removeLeft: true,
                child: SafeArea(child: widget.child),
              ),
            ),
          ),
        ),
      );
}
