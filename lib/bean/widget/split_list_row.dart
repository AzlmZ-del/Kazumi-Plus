import 'package:flutter/material.dart';

import 'package:kazumi/bean/widget/tonal_card.dart';

const double splitListOuterRadius = tonalCardRadius;
const double splitListInnerRadius = 4;
const double splitListRowGap = 4;

const Duration splitListMotionDuration = Duration(milliseconds: 250);
const Curve splitListMotionCurve = Curves.easeInOutCubic;

class SplitListRow extends StatefulWidget {
  const SplitListRow({
    super.key,
    required this.child,
    this.topRadius = splitListInnerRadius,
    this.bottomRadius = splitListInnerRadius,
    this.pressedRadius = splitListOuterRadius,
    this.onTap,
  });

  final Widget child;

  final double topRadius;
  final double bottomRadius;
  final double pressedRadius;
  final VoidCallback? onTap;

  /// 把子级 InkWell 的 onHighlightChanged 转发到这里。
  static ValueChanged<bool>? pressReporterOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_SplitRowScope>()
        ?.onPressChanged;
  }

  @override
  State<SplitListRow> createState() => _SplitListRowState();
}

class _SplitListRowState extends State<SplitListRow> {
  bool _pressed = false;

  void _reportPress(bool pressed) => setState(() => _pressed = pressed);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final child = widget.onTap == null
        ? widget.child
        : InkWell(
            onTap: widget.onTap,
            onHighlightChanged: _reportPress,
            child: widget.child,
          );
    // 颜色也要跟着动，Material 默认只对形状做过渡、颜色是硬切。
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : splitListMotionDuration,
      curve: splitListMotionCurve,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(
              _pressed ? widget.pressedRadius : widget.topRadius),
          bottom: Radius.circular(
              _pressed ? widget.pressedRadius : widget.bottomRadius),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTileTheme(
          data: theme.listTileTheme.copyWith(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            titleTextStyle:
                theme.textTheme.bodyLarge?.copyWith(color: colors.onSurface),
            subtitleTextStyle: theme.textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          child: _SplitRowScope(onPressChanged: _reportPress, child: child),
        ),
      ),
    );
  }
}

class _SplitRowScope extends InheritedWidget {
  const _SplitRowScope({required this.onPressChanged, required super.child});

  final ValueChanged<bool> onPressChanged;

  // 回调恒定指向同一个 state，无需通知重建。
  @override
  bool updateShouldNotify(_SplitRowScope oldWidget) => false;
}

class SplitListGroup extends StatelessWidget {
  const SplitListGroup({
    super.key,
    required this.children,
    this.outerRadius = splitListOuterRadius,
  });

  final List<Widget> children;

  final double outerRadius;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: splitListRowGap),
          SplitListRow(
            topRadius: i == 0 ? outerRadius : splitListInnerRadius,
            bottomRadius:
                i == children.length - 1 ? outerRadius : splitListInnerRadius,
            pressedRadius: outerRadius,
            child: children[i],
          ),
        ],
      ],
    );
  }
}
