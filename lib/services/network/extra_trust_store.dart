import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';

/// 补充运行时缺失的信任锚。
///
/// Dart/Flutter 的 BoringSSL 内置根集合是 engine 打包时的快照，且在链构建
/// 上不如系统验证器灵活（不会智能选择 cross-signed 中间证书路径）。
/// 部分站点（如 agedm.io，2026-10 起改用 SSL.com TLS RSA Root CA 2022
/// 签发的证书）会因此握手失败：`CERTIFICATE_VERIFY_FAILED: unable to get
/// local issuer certificate`，在 Dio 层表现为 `DioExceptionType.unknown`。
/// 浏览器 / curl / Python 均正常，唯独 Dart 运行时失败。
///
/// 解决：把 SSL.com TLS RSA Root CA 2022 与其中间证书
/// （SSL.com TLS Issuing RSA CA R1）随应用内置，启动时并入默认信任库。
/// 两者均为公开可分发的 CA 证书（PEM 拼接文件）。
class ExtraTrustStore {
  ExtraTrustStore._();

  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    try {
      final pem = await rootBundle.loadString('assets/cert/ssl_com_root_2022.pem');
      SecurityContext.defaultContext.setTrustedCertificatesBytes(
        utf8.encode(pem),
      );
      _loaded = true;
    } catch (e) {
      // 信任库加载失败只影响个别站点的证书校验，不应阻塞启动。
      KazumiLogger().w('ExtraTrustStore: 附加信任锚加载失败 $e');
    }
  }
}
