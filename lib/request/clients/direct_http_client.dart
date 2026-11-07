import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:kazumi/request/core/network_exception.dart';

/// Android 原生直连通道：绕过 TUN 型 VPN 发起一次 HTTP 请求。
///
/// 为什么需要它：Android 上的 Clash 等是 TUN 型 VPN，内核按 uid 把流量塞进
/// tun0，Dart 的 `HttpClient.findProxy` 完全无效（实测：findProxy 设 DIRECT
/// 依旧 7.3s 握手超时）。只有用 ConnectivityManager.requestNetwork() 明确
/// 排除 VPN 拿到物理网络，再在该网络上 openConnection 才能真正直连。
///
/// 仅 Android 且有 VPN 时启用；其余平台由 DioFactory.pluginDirectDio 处理。
class DirectHttpClient {
  DirectHttpClient._();

  static const _channel = MethodChannel('com.predidit.kazumi/direct_http');

  /// 当前系统是否有 VPN 网络接管流量。非 Android 恒为 false。
  static Future<bool> isVpnActive() async {
    if (!Platform.isAndroid) return false;
    try {
      final active = await _channel.invokeMethod<bool>('isVpnActive');
      return active ?? false;
    } catch (_) {
      return false;
    }
  }

  /// PoC：启动本地 CONNECT 隧道（绑定非 VPN 网卡），返回监听端口。
  /// 已有隧道在跑时直接返回其端口。失败抛异常。
  static Future<int> startLocalProxy() async {
    final port = await _channel.invokeMethod<int>('startLocalProxy');
    if (port == null) throw StateError('startLocalProxy 未返回端口');
    return port;
  }

  /// 关闭本地 CONNECT 隧道（播放器销毁时调用）。
  static Future<void> stopLocalProxy() async {
    try {
      await _channel.invokeMethod('stopLocalProxy');
    } catch (_) {}
  }

  /// 走非 VPN 网络发起请求，返回响应正文。
  ///
  /// [bodyType] 与 Dio 路径保持一致（'json' / 'form' / 'none'）：Dio 会自动
  /// 把 Map 序列化成 JSON，而原生通道用 HttpURLConnection 必须自己来，否则
  /// 会把 Dart Map 的 toString()（形如 `{p_keyword: FX}`）当正文发出去，
  /// 服务端返回 PGRST102 "Empty or invalid json"。
  ///
  /// 失败时抛 [NetworkException]，与其他请求路径的错误类型保持一致。
  static Future<String> request({
    required String url,
    required String method,
    Map<String, dynamic> headers = const {},
    Object? body,
    String bodyType = 'json',
  }) async {
    try {
      final payload = encodeBody(body, bodyType);
      final text = await _channel.invokeMethod<String>('request', {
        'url': url,
        'method': method.toUpperCase(),
        'headers': headers.map((key, value) => MapEntry(key, '$value')),
        'body': payload,
      });
      return text ?? '';
    } on PlatformException catch (error) {
      throw NetworkException(
        type: NetworkExceptionType.connectionError,
        message: '直连失败：${error.message ?? error.code}',
        stackTrace: StackTrace.current,
      );
    } on MissingPluginException {
      throw NetworkException(
        type: NetworkExceptionType.connectionError,
        message: '直连通道不可用（原生插件未注册）',
        stackTrace: StackTrace.current,
      );
    }
  }

  /// 按 bodyType 把请求体序列化成字符串；无需 body 时返回 null。
  ///
  /// 可见于测试。
  static String? encodeBody(Object? body, String bodyType) {
    if (body == null) return null;
    switch (bodyType) {
      case 'json':
        // 规则模板直接给了 JSON 原文时原样发送，避免双重编码。
        return body is String ? body : jsonEncode(body);
      case 'form':
        if (body is Map) {
          return body.entries
              .map((entry) =>
                  '${Uri.encodeQueryComponent('${entry.key}')}='
                  '${Uri.encodeQueryComponent('${entry.value}')}')
              .join('&');
        }
        return '$body';
      default:
        return null;
    }
  }
}
