import 'dart:io';

import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/device.dart';
import 'package:window_manager/window_manager.dart';

class DisplayModeService {
  DisplayModeService._();

  static const _intentChannel = MethodChannel('com.predidit.kazumi/intent');
  static Future<void> _pendingFullscreen = Future.value();
  static Future<void>? _pendingSystemBars;
  static Object? _systemBarsOwner;
  static bool _systemBarsHidden = false;

  static Future<void> applyVideoFullscreen(bool fullscreen) {
    return _pendingFullscreen = _pendingFullscreen.then((_) async {
      if (isDesktop()) {
        await _attempt(() => windowManager.setFullScreen(fullscreen));
        return;
      }

      // 退出时恢复系统方向，原本就是横屏的也要还原。
      await _attempt(() => SystemChrome.setPreferredOrientations(
            fullscreen
                ? [
                    DeviceOrientation.landscapeLeft,
                    DeviceOrientation.landscapeRight
                  ]
                : [],
          ));
    });
  }

  /// 正在离开的页面不能释放属于下一个可见页面的系统栏控制权。
  static Future<void> setSystemBarsHidden({
    required Object owner,
    required bool hidden,
  }) {
    _systemBarsOwner = owner;
    return _setSystemBarsHidden(hidden);
  }

  static Future<void> releaseSystemBars(Object owner) {
    if (!identical(_systemBarsOwner, owner)) {
      return _pendingSystemBars ?? Future.value();
    }
    _systemBarsOwner = null;
    return _setSystemBarsHidden(false);
  }

  static Future<void> _setSystemBarsHidden(bool hidden) {
    if (_systemBarsHidden == hidden) {
      return _pendingSystemBars ?? Future.value();
    }
    _systemBarsHidden = hidden;
    // 旋转回执不能拖慢沉浸式切换或路由清理。
    late final Future<void> request;
    request = (_pendingSystemBars ?? Future<void>.value())
        .then((_) => _attempt(() async {
              if (Platform.isAndroid) {
                await _intentChannel.invokeMethod(
                    'setSystemBarsHidden', hidden);
              } else if (Platform.isIOS) {
                await SystemChrome.setEnabledSystemUIMode(
                  hidden
                      ? SystemUiMode.immersiveSticky
                      : SystemUiMode.edgeToEdge,
                );
              }
            }))
        .whenComplete(() {
      if (identical(_pendingSystemBars, request)) _pendingSystemBars = null;
    });
    return _pendingSystemBars = request;
  }

  static Future<void> _attempt(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error, stackTrace) {
      KazumiLogger().e('Display: failed to apply video display mode',
          error: error, stackTrace: stackTrace);
    }
  }
}
