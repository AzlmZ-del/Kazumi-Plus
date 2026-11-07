import 'dart:async';

const startupUpdateCheckDelay = Duration(milliseconds: 500);

/// 启动更新检查独立运行，不依附于发起它的那个页面。
///
/// 启动页通常在跳到应用外壳后立即被销毁，所以这项工作不能依赖
/// 它的 [State.mounted]。
Future<void> runStartupUpdateCheck({
  required bool Function() isEnabled,
  required Future<void> Function() checkForUpdate,
  Duration delay = startupUpdateCheckDelay,
}) async {
  await Future<void>.delayed(delay);
  if (!isEnabled()) {
    return;
  }
  await checkForUpdate();
}
