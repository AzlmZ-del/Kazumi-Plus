import 'package:kazumi/services/storage/storage.dart';

abstract final class DesktopWindowConfig {
  /// 在窗口初始化时取值；偏好改动要下次启动才生效。
  static final bool showWindowButton = GStorage.getSetting(
    SettingsKeys.showWindowButton,
  );
}
