import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

import 'package:kazumi/bean/dialog/kazumi_toast_host.dart';

/// 圆角胶囊样式的轻提示。
///
/// 用 `FToast` 的 Overlay 通道显示（不是系统 Toast），所以圆角、颜色、
/// 阴影、内边距全部可自定义，也不受 Android 原生 Toast 位置限制。
class KazumiToastBubble extends StatelessWidget {
  const KazumiToastBubble({
    super.key,
    required this.message,
    this.actionLabel,
    this.onActionPressed,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onActionPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hasAction = actionLabel != null && onActionPressed != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: colors.shadow.withValues(alpha: 0.18),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 12, hasAction ? 8 : 20, 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onPrimaryContainer,
                      height: 1.35,
                    ),
                  ),
                ),
                if (hasAction) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: colors.onPrimaryContainer,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      minimumSize: const Size(48, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: onActionPressed,
                    child: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 显示一条胶囊提示。
///
/// [anchorContext] 必须能向上找到 `FToastBuilder` 提供的 `Overlay`
/// （`MaterialApp.builder` 里已经包好，见 `KazumiToastHost`）。
/// 传 null 时退回全局锚点 [toastAnchorKey]。
void showKazumiToast({
  required String message,
  BuildContext? anchorContext,
  String? actionLabel,
  VoidCallback? onActionPressed,
  Duration duration = const Duration(seconds: 2),
}) {
  final anchor = _resolveAnchor(anchorContext);
  if (anchor == null) {
    debugPrint('Kazumi Toast Error: No overlay anchor available');
    return;
  }
  final fToast = FToast()..init(anchor);
  // 新提示直接顶掉旧的，不排队（与原先 SnackBar 的行为一致）。
  fToast.removeCustomToast();
  fToast.showToast(
    toastDuration: duration,
    fadeDuration: const Duration(milliseconds: 200),
    isDismissible: true,
    // 自己算位置：抬高 88dp 避开底部导航条，并随键盘上移。
    positionedToastBuilder: (context, child, _) => Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.viewInsetsOf(context).bottom + 88,
      child: child,
    ),
    child: KazumiToastBubble(
      message: message,
      actionLabel: actionLabel,
      onActionPressed: onActionPressed,
    ),
  );
}

/// 立刻收起当前提示（换页时用）。
void dismissKazumiToast() {
  FToast().removeCustomToast();
}

/// 选出往哪个 Overlay 插提示。
///
/// 优先用全局锚点 [toastAnchorKey] —— 它挂在 `MaterialApp.builder` 里的
/// `FToastBuilder` 内部，位于 **Navigator 之上**，因此换页、弹对话框都不会
/// 把提示压在下面。调用方 context 只作兜底（例如锚点尚未挂载时）。
BuildContext? _resolveAnchor(BuildContext? preferred) {
  final anchor = toastAnchorKey.currentContext;
  if (anchor != null && anchor.mounted && Overlay.maybeOf(anchor) != null) {
    return anchor;
  }
  if (preferred != null && preferred.mounted) {
    final overlay = Overlay.maybeOf(preferred);
    if (overlay != null) return preferred;
  }
  return null;
}
