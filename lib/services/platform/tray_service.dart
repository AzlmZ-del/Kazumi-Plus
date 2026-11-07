import 'dart:io';

import 'package:tray_manager/tray_manager.dart';

class TrayService {
  TrayService._();

  static bool _iconSet = false;

  static Future<void> initialize() async {
    if (Platform.isWindows) {
      await trayManager.setIcon('assets/images/logo/logo_lanczos.ico');
    } else if (Platform.environment.containsKey('FLATPAK_ID') ||
        Platform.environment.containsKey('SNAP')) {
      await trayManager.setIcon('io.github.Predidit.Kazumi');
    } else {
      await trayManager.setIcon('assets/images/logo/logo_rounded.png');
    }
    _iconSet = true;

    if (!Platform.isLinux) {
      await trayManager.setToolTip('Kazumi Plus');
    }

    Menu trayMenu = Menu(items: [
      MenuItem(key: 'show_window', label: '显示窗口'),
      MenuItem.separator(),
      MenuItem(key: 'exit', label: '退出 Kazumi Plus')
    ]);
    await trayManager.setContextMenu(trayMenu);
  }

  /// 必须在 exit() 之前执行：该插件只在 WM_DESTROY 时才清理 Windows 图标，
  /// 而它的销毁逻辑假定此前设置过图标。
  static Future<void> dispose() async {
    if (!_iconSet) return;
    _iconSet = false;
    await trayManager.destroy();
  }
}
