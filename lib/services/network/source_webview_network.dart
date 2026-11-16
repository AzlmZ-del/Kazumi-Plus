import 'dart:io';

import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart'
    as android_webview;
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/source_network_service.dart';
import 'package:kazumi/services/network/source_proxy_lease.dart';

/// 内置浏览器拿到的出口：租约负责页面存续期间保持该出口，
/// [notice] 非空表示没能兑现规则设定，界面应提示但仍继续打开。
class SourceBrowserNetwork {
  const SourceBrowserNetwork({required this.lease, this.notice});

  final SourceProxyLease lease;
  final String? notice;
}

class SourceWebviewNetwork {
  SourceWebviewNetwork._();

  static final _android = SourceProxyLeaseManager(
    apply: _applyAndroid,
    restore: () => _applyAndroid(SourceNetworkService.defaultRoute(null)),
  );

  /// 内置浏览器的出口结果：[notice] 非空表示没能完全兑现，调用方应提示用户
  /// 但仍照常打开页面——内置浏览只是辅助看页面，不该因此白屏。
  static Future<SourceBrowserNetwork> acquireForBrowser(
    SourceNetworkRoute route, {
    Future<void>? cancelled,
  }) async {
    final deliverable = adaptRoute(route);
    final degraded = deliverable != route;
    if (!Platform.isAndroid) {
      return SourceBrowserNetwork(
        lease: SourceProxyLease(() async {}),
        notice: degraded
            ? '当前平台的内置浏览器无法强制直连，已按 ${deliverable.mode.name} 出口打开'
            : null,
      );
    }
    final supported = await android_webview.AndroidWebViewFeature.instance()
        .isFeatureSupported(WebViewFeature.PROXY_OVERRIDE);
    if (!supported) {
      return SourceBrowserNetwork(
        lease: SourceProxyLease(() async {}),
        notice: deliverable.isDirect || deliverable.usesProxy
            ? '当前 Android WebView 不支持代理覆盖，已按系统网络打开'
            : null,
      );
    }
    return SourceBrowserNetwork(
      lease: await _android.acquire(deliverable, cancelled: cancelled),
    );
  }

  /// 能真正兑现直连的平台：Android 有非 VPN 网关，Windows 的 WebView2
  /// 支持 `--no-proxy-server`。Linux 的 WebView 只能在创建时给一个 http
  /// 代理、无法强制 DIRECT；macOS 的 route 参数没有落地通道，同样不算支持。
  static bool get supportsForcedDirect =>
      Platform.isAndroid || Platform.isWindows;

  /// 把规则声明的出口折算成该平台 WebView 实际能兑现的出口。
  ///
  /// 无法强制 DIRECT 的平台（Linux、macOS）退回该平台原本的加载方式
  /// ——[SourceNetworkService.defaultRoute] 给出的全局代理或系统网络，
  /// 而不是拒绝打开：规则直连是尽力而为，页面对用户仍然要能看。
  /// 搜索与详情走原生 HTTP 通道，不受这里影响，仍可真正直连。
  static SourceNetworkRoute adaptRoute(
    SourceNetworkRoute route, {
    bool? forcedDirectSupported,
    SourceNetworkRoute Function(Uri? target)? fallback,
  }) {
    final supported = forcedDirectSupported ?? supportsForcedDirect;
    if (supported || !route.isDirect) {
      return route;
    }
    // 降级目标沿用该平台原本的加载方式；注入点便于测试脱离 Hive 设置。
    final resolved = (fallback ?? SourceNetworkService.defaultRoute)(null);
    KazumiLogger().w(
      'WebView: 当前平台无法强制直连，已按 ${resolved.mode.name} 出口打开',
    );
    return resolved;
  }

  static Future<SourceProxyLease> acquire(
    SourceNetworkRoute route, {
    Future<void>? cancelled,
  }) async {
    final deliverable = adaptRoute(route);
    if (!Platform.isAndroid) {
      return SourceProxyLease(() async {});
    }
    return _android.acquire(deliverable, cancelled: cancelled);
  }

  static Future<void> _applyAndroid(SourceNetworkRoute route) async {
    final supported = await android_webview.AndroidWebViewFeature.instance()
        .isFeatureSupported(WebViewFeature.PROXY_OVERRIDE);
    if (!supported) {
      // 直连承诺无法兑现必须失败；普通代理保持旧行为，告警后跟随系统网络。
      if (route.isDirect) {
        throw UnsupportedError('当前 Android WebView 不支持代理覆盖，无法应用规则直连');
      }
      if (route.usesProxy) {
        KazumiLogger().w('WebView: 当前 Android WebView 不支持代理覆盖，跟随系统网络');
      }
      return;
    }
    final controller = android_webview.AndroidProxyController.instance();
    try {
      if (route.mode == SourceNetworkMode.system) {
        await controller.clearProxyOverride();
      } else {
        await controller.setProxyOverride(
          settings: route.usesProxy
              ? ProxySettings(proxyRules: [ProxyRule(url: route.proxyUrl!)])
              : ProxySettings(directs: const ['*']),
        );
      }
    } catch (error) {
      KazumiLogger().w('WebView: 网络出口应用失败 $error');
      rethrow;
    }
  }
}
