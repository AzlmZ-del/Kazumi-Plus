import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/network/source_network_route.dart';
import 'package:kazumi/services/network/source_webview_network.dart';

void main() {
  test('ordinary route opens without any notice', () async {
    final result = await SourceWebviewNetwork.acquireForBrowser(
      const SourceNetworkRoute.system(),
    );
    expect(result.notice, isNull);
    await result.lease.release();
  });

  test('Windows can force direct, so no limitation notice is shown', () async {
    // WebView2 支持 --no-proxy-server，桌面直连是真正可兑现的。
    expect(Platform.isWindows, isTrue, reason: 'test host is Windows');
    final result = await SourceWebviewNetwork.acquireForBrowser(
      const SourceNetworkRoute.direct(),
    );
    expect(result.notice, isNull);
    await result.lease.release();
  });

  test('desktop proxy route still opens silently', () async {
    final result = await SourceWebviewNetwork.acquireForBrowser(
      SourceNetworkRoute.proxy(Uri.parse('http://127.0.0.1:7897')),
    );
    expect(result.notice, isNull);
    await result.lease.release();
  });

  test(
    'Windows gateway route is direct and supported without notice',
    () async {
      final result = await SourceWebviewNetwork.acquireForBrowser(
        SourceNetworkRoute.gateway(9000),
      );
      expect(result.notice, isNull);
      await result.lease.release();
    },
  );

  test(
    'Windows direct route is accepted by the enforcing acquire path',
    () async {
      // 抓源路径走 acquire：Windows 上不应再抛「不支持直连」。
      final lease = await SourceWebviewNetwork.acquire(
        const SourceNetworkRoute.direct(),
      );
      await lease.release();
    },
  );

  test('supported platforms include Android and Windows', () {
    // Android 走非 VPN 网关、Windows 走 --no-proxy-server，两者都能兑现直连；
    // Linux 只能在创建时给 http 代理、macOS 的 route 没有落地通道，仍不支持。
    // 这里钉住平台集合，避免只改一边导致 Android 直连源被误判为不支持。
    expect(
      SourceWebviewNetwork.supportsForcedDirect,
      equals(Platform.isAndroid || Platform.isWindows),
    );
    if (Platform.isAndroid || Platform.isWindows) {
      expect(SourceWebviewNetwork.supportsForcedDirect, isTrue);
    }
  });

  test('platforms without forced direct downgrade instead of failing', () {
    // Linux / macOS 无法强制 DIRECT：规则直连退回该平台原本的加载方式，
    // 而不是拒绝打开——否则这些平台的直连源会完全播不了。
    final fallback = SourceNetworkRoute.proxy(
      Uri.parse('http://127.0.0.1:7897'),
    );
    for (final route in <SourceNetworkRoute>[
      const SourceNetworkRoute.direct(),
      SourceNetworkRoute.gateway(9000),
    ]) {
      final adapted = SourceWebviewNetwork.adaptRoute(
        route,
        forcedDirectSupported: false,
        fallback: (_) => fallback,
      );
      expect(adapted, equals(fallback));
      expect(adapted.isDirect, isFalse);
    }
  });

  test('platforms with forced direct keep the requested route intact', () {
    final adapted = SourceWebviewNetwork.adaptRoute(
      const SourceNetworkRoute.direct(),
      forcedDirectSupported: true,
      fallback: (_) => throw StateError('must not downgrade'),
    );
    expect(adapted.mode, SourceNetworkMode.direct);
  });

  test('non-direct routes are never rewritten by the downgrade', () {
    final proxy = SourceNetworkRoute.proxy(Uri.parse('http://127.0.0.1:7897'));
    expect(
      SourceWebviewNetwork.adaptRoute(
        proxy,
        forcedDirectSupported: false,
        fallback: (_) => throw StateError('must not rewrite proxy routes'),
      ),
      equals(proxy),
    );
  });

  test('a downgraded route carries a proxy the platform can actually set', () {
    // Linux 的内置浏览器只能接受 host:port 形式的 http 代理；降级结果如果是
    // direct 或 system（proxyUrl 为 null），窗口就会悄无声息地走系统网络。
    final adapted = SourceWebviewNetwork.adaptRoute(
      const SourceNetworkRoute.direct(),
      forcedDirectSupported: false,
      fallback: (_) => SourceNetworkRoute.proxy(
        Uri.parse('http://127.0.0.1:7897'),
      ),
    );
    expect(adapted.proxyUrl, 'http://127.0.0.1:7897');
    final parsed = ProxyUtils.parseProxyUrl(adapted.proxyUrl!);
    expect(parsed, isNotNull);
    expect(parsed!.$1, '127.0.0.1');
    expect(parsed.$2, 7897);
  });
}
