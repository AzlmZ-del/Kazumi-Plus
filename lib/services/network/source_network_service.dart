import 'dart:io';

import 'package:kazumi/request/clients/direct_http_client.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/network/source_network_route.dart';
import 'package:kazumi/services/network/system_proxy_service.dart';
import 'package:kazumi/services/storage/storage.dart';

export 'source_network_route.dart';

class SourceNetworkService {
  SourceNetworkService._();

  static final resolver = SourceNetworkResolver(
    isAndroid: Platform.isAndroid,
    isVpnActive: DirectHttpClient.isVpnActive,
    startGateway: DirectHttpClient.startLocalProxy,
    defaultRoute: defaultRoute,
  );

  static SourceNetworkRoute defaultRoute(Uri? target) {
    final bool enabled = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (enabled) {
      final String value = GStorage.getSetting(SettingsKeys.proxyUrl);
      final formatted = ProxyUtils.getFormattedProxyUrl(value);
      if (formatted != null) {
        return SourceNetworkRoute.proxy(
          Uri.parse(formatted),
          allowBadCertificates: true,
        );
      }
    }
    if (Platform.isWindows && target != null) {
      final value = SystemProxyService.findProxy(target);
      if (value.startsWith('PROXY ')) {
        return SourceNetworkRoute.proxy(
          Uri.parse('http://${value.substring(6)}'),
        );
      }
    }
    return const SourceNetworkRoute.system();
  }
}
