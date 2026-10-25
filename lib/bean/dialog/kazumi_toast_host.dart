import 'package:flutter/material.dart';

/// FToast 的全局挂载点。
///
/// `FToast.showToast` 内部要 `Overlay.of(context)`，也就是说它拿到的
/// `BuildContext` **必须有一个 Overlay 祖先**。而 `rootScaffoldMessengerKey`
/// 的 context 在 MaterialApp 里位于 Navigator 之上（ScaffoldMessenger 包着
/// Navigator），没有 Overlay 祖先；`rootNavigatorKey.currentContext` 也一样，
/// 它拿到的是 Navigator 自己，Overlay 在它下面。
///
/// 所以这里在 `MaterialApp.builder` 里再包一层 `FToastBuilder()`，并把本组件
/// 作为它的 child 放进去 —— 本组件的 context 就落在 FToastBuilder 那个
/// Overlay 的内部，任何调用方（包括不传 context 的 `KazumiDialog.showToast`）
/// 都能借它插浮层。它本身不渲染任何东西，只是提供一个稳定的锚点。
class KazumiToastHost extends StatelessWidget {
  const KazumiToastHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// 全局 toast 锚点的 key，挂在 [KazumiToastHost] 上。
final GlobalKey toastAnchorKey = GlobalKey(debugLabel: 'KazumiToastHost');
