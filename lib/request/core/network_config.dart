import 'dart:io';

import 'package:dio/io.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/network/system_proxy_service.dart';
import 'package:kazumi/services/storage/storage.dart';

class NetworkConfig {
  const NetworkConfig({
    this.connectTimeout = const Duration(seconds: 12),
    this.receiveTimeout = const Duration(seconds: 12),
    this.sendTimeout,
    this.proxyHost,
    this.proxyPort,
    this.forceDirect = false,
    this.allowBadCertificates = false,
    this.enableLog = true,
  });

  final Duration connectTimeout;
  final Duration receiveTimeout;
  final Duration? sendTimeout;
  final String? proxyHost;
  final int? proxyPort;
  final bool allowBadCertificates;
  final bool enableLog;

  bool get hasProxy => proxyHost != null && proxyPort != null;

  /// true = 完全不使用代理（连 Windows 系统代理回调也不挂）。
  /// 用于规则级直连：规则声明绕过代理时，系统代理与手动代理一并失效。
  final bool forceDirect;


  Uri? proxyForUri(Uri uri) {
    if (hasProxy) return Uri(scheme: 'http', host: proxyHost, port: proxyPort);
    if (Platform.isWindows) {
      final proxy = SystemProxyService.findProxy(uri);
      if (proxy.startsWith('PROXY ')) {
        return Uri.parse('http://${proxy.substring(6)}');
      }
    }
    return null;
  }

  IOHttpClientAdapter createAdapter() {
    return IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        if (forceDirect) {
          // 显式 DIRECT：仅仅「不挂代理回调」是不够的 —— dart:io 的 HttpClient
          // 在 findProxy 为 null 时会回落到 HTTP_PROXY / HTTPS_PROXY 环境变量，
          // 规则级直连因此会照样走系统代理（实测 2026-11-06：环境里带
          // HTTPS_PROXY=127.0.0.1:7897 时，直连请求稳定 7.2s 后 TLS 握手被掐断）。
          client.findProxy = (_) => 'DIRECT';
        } else if (hasProxy) {
          client.findProxy = (_) => 'PROXY $proxyHost:$proxyPort';
        } else if (Platform.isWindows) {
          client.findProxy = SystemProxyService.findProxy;
        }
        if (allowBadCertificates) {
          client.badCertificateCallback = (cert, host, port) => true;
        }
        return client;
      },
    );
  }

  NetworkConfig copyWith({
    Duration? connectTimeout,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    String? proxyHost,
    int? proxyPort,
    bool? clearProxy,
    bool? allowBadCertificates,
    bool? enableLog,
  }) {
    final shouldClearProxy = clearProxy ?? false;
    return NetworkConfig(
      connectTimeout: connectTimeout ?? this.connectTimeout,
      receiveTimeout: receiveTimeout ?? this.receiveTimeout,
      sendTimeout: sendTimeout ?? this.sendTimeout,
      proxyHost: shouldClearProxy ? null : proxyHost ?? this.proxyHost,
      proxyPort: shouldClearProxy ? null : proxyPort ?? this.proxyPort,
      allowBadCertificates: allowBadCertificates ?? this.allowBadCertificates,
      enableLog: enableLog ?? this.enableLog,
    );
  }

  static NetworkConfig fromSettings({
    Duration connectTimeout = const Duration(seconds: 12),
    Duration receiveTimeout = const Duration(seconds: 12),
    Duration? sendTimeout,
  }) {
    final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (!proxyEnable) {
      return NetworkConfig(
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
      );
    }

    final proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
    final parsed = ProxyUtils.parseProxyUrl(proxyUrl);
    if (parsed == null) {
      KazumiLogger().w('Proxy: 代理地址格式错误或为空');
      return NetworkConfig(
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
      );
    }

    return NetworkConfig(
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
      proxyHost: parsed.$1,
      proxyPort: parsed.$2,
      allowBadCertificates: true,
    );
  }
}
