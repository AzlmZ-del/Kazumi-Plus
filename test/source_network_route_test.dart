import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/source_network_route.dart';

void main() {
  SourceNetworkResolver resolver({
    bool android = true,
    Future<bool> Function()? vpn,
    Future<int> Function()? gateway,
    SourceNetworkRoute Function(Uri?)? normal,
  }) => SourceNetworkResolver(
    isAndroid: android,
    isVpnActive: vpn ?? () async => true,
    startGateway: gateway ?? () async => 9000,
    defaultRoute: normal ?? (_) => const SourceNetworkRoute.system(),
  );

  test(
    'ordinary sources keep their selected proxy without probing VPN',
    () async {
      final proxy = Uri.parse('http://127.0.0.1:7897');
      final route =
          await resolver(
            vpn: () => throw StateError('unexpected VPN probe'),
            gateway: () => throw StateError('unexpected gateway'),
            normal: (target) {
              expect(target!.host, 'example.com');
              return SourceNetworkRoute.proxy(proxy);
            },
          ).resolve(
            directConnection: false,
            target: Uri.parse('https://example.com'),
          );
      expect(route.mode, SourceNetworkMode.proxy);
      expect(route.proxy, proxy);
      expect(route.isDirect, isFalse);
    },
  );

  test('Android VPN direct sources share the native gateway', () async {
    final route = await resolver(
      normal: (_) => throw StateError('fallback'),
    ).resolve(directConnection: true);
    expect(route.mode, SourceNetworkMode.directGateway);
    expect(route.proxyUrl, 'http://127.0.0.1:9000');
    expect(route.isDirect, isTrue);
    expect(route.allowBadCertificates, isFalse);
  });

  test('Android without VPN explicitly bypasses HTTP proxies', () async {
    final route = await resolver(
      vpn: () async => false,
      gateway: () => throw StateError('unexpected gateway'),
    ).resolve(directConnection: true);
    expect(route.mode, SourceNetworkMode.direct);
    expect(route.proxy, isNull);
  });

  test('desktop direct requests never call the Android bridge', () async {
    final route = await resolver(
      android: false,
      vpn: () => throw StateError('unexpected VPN probe'),
      gateway: () => throw StateError('unexpected gateway'),
    ).resolve(directConnection: true);
    expect(route.mode, SourceNetworkMode.direct);
  });

  test('gateway failure does not fall back to the configured proxy', () async {
    var fallbacks = 0;
    await expectLater(
      resolver(
        gateway: () async => throw StateError('no physical network'),
        normal: (_) {
          fallbacks++;
          return const SourceNetworkRoute.system();
        },
      ).resolve(directConnection: true),
      throwsStateError,
    );
    expect(fallbacks, 0);
  });

  test('unknown VPN state does not silently become ordinary direct', () async {
    await expectLater(
      resolver(
        vpn: () async => throw StateError('missing native channel'),
      ).resolve(directConnection: true),
      throwsStateError,
    );
  });

  test('gateway rejects invalid ports', () {
    expect(() => SourceNetworkRoute.gateway(0), throwsArgumentError);
    expect(() => SourceNetworkRoute.gateway(65536), throwsArgumentError);
  });

  test('route equality keeps direct gateway and manual proxy separate', () {
    final gateway = SourceNetworkRoute.gateway(9000);
    expect(gateway, SourceNetworkRoute.gateway(9000));
    expect(gateway.hashCode, SourceNetworkRoute.gateway(9000).hashCode);
    expect(gateway, isNot(SourceNetworkRoute.proxy(gateway.proxy!)));
  });
}
