import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/utils/async_single_flight.dart';

/// Android 非 VPN 网关桥接；HTTP 请求、响应和取消仍由 Dio 处理。
class DirectHttpClient {
  DirectHttpClient._();

  static const _channel = MethodChannel('com.predidit.kazumi/direct_http');
  static final _starting = AsyncSingleFlight<int>();

  static Future<bool> isVpnActive() async {
    if (!Platform.isAndroid) return false;
    try {
      final active = await _channel.invokeMethod<bool>('isVpnActive');
      if (active == null) throw StateError('VPN 状态未返回');
      return active;
    } catch (error, stackTrace) {
      throw _failure('无法确认直连网络状态', error, stackTrace);
    }
  }

  /// 网关按 App 生命周期复用，不随切集销毁。
  static Future<int> startLocalProxy() => _starting.run(() async {
    try {
      final port = await _channel
          .invokeMethod<int>('startLocalProxy')
          .timeout(const Duration(seconds: 12));
      if (port == null || port < 1 || port > 65535) {
        throw StateError('直连网关未返回有效端口');
      }
      return port;
    } catch (error, stackTrace) {
      throw _failure('直连网关不可用', error, stackTrace);
    }
  });

  static Future<void> stopLocalProxy() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stopLocalProxy');
  }

  static NetworkException _failure(
    String message,
    Object error,
    StackTrace stackTrace,
  ) {
    final detail = error is PlatformException
        ? error.message
        : error.toString();
    return NetworkException(
      type: error is TimeoutException
          ? NetworkExceptionType.connectionTimeout
          : NetworkExceptionType.connectionError,
      message: '$message：$detail',
      rawError: error,
      stackTrace: stackTrace,
    );
  }
}
