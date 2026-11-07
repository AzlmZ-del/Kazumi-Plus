import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/services/logging/logger.dart';

class MeteredNetworkService {
  MeteredNetworkService._();

  static final ValueNotifier<bool> _metered = ValueNotifier<bool>(false);
  static StreamSubscription<List<ConnectivityResult>>? _subscription;
  static int _revision = 0;

  static bool get _supported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static bool get isMetered => _metered.value;

  static ValueListenable<bool> get listenable => _metered;

  static Future<void> refresh() async {
    if (!_supported) return;
    final revision = ++_revision;
    try {
      // 错过后台网络变化后，要重置事件去重状态。
      final previous = _subscription;
      _subscription = null;
      await previous?.cancel();
      if (revision != _revision) return;
      _subscription = Connectivity().onConnectivityChanged.listen(
        (results) {
          _revision++;
          _apply(results);
        },
        onError: (Object error) {
          KazumiLogger().w('Network: 网络类型监听中断 $error');
        },
      );
      final results = await Connectivity()
          .checkConnectivity()
          .timeout(const Duration(seconds: 3));
      // 被刷新或网络事件顶替掉的查询要丢掉。
      if (revision == _revision) {
        _apply(results);
      }
    } catch (error) {
      KazumiLogger().w('Network: 读取网络类型失败，保留上次状态 $error');
    }
  }

  static void _apply(List<ConnectivityResult> results) {
    final metered = _isMetered(results);
    if (metered == null || metered == _metered.value) {
      return;
    }
    KazumiLogger()
        .i(metered ? 'Network: 切换到移动数据网络' : 'Network: 切换到 WLAN / 局域网');
    _metered.value = metered;
  }

  // 切换网络时以 WLAN 为准；无法识别的传输方式沿用上次已知状态。
  static bool? _isMetered(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet)) {
      return false;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return true;
    }
    return null;
  }
}
