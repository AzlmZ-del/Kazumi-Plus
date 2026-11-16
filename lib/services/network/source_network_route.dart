enum SourceNetworkMode { system, proxy, direct, directGateway }

class SourceNetworkRoute {
  const SourceNetworkRoute.system()
    : mode = SourceNetworkMode.system,
      proxy = null,
      allowBadCertificates = false;

  const SourceNetworkRoute.direct()
    : mode = SourceNetworkMode.direct,
      proxy = null,
      allowBadCertificates = false;

  const SourceNetworkRoute.proxy(
    Uri address, {
    this.allowBadCertificates = false,
  }) : mode = SourceNetworkMode.proxy,
       proxy = address;

  SourceNetworkRoute.gateway(int port)
    : mode = SourceNetworkMode.directGateway,
      proxy = Uri(scheme: 'http', host: '127.0.0.1', port: port),
      allowBadCertificates = false {
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'Invalid gateway port');
    }
  }

  final SourceNetworkMode mode;
  final Uri? proxy;
  final bool allowBadCertificates;

  bool get isDirect =>
      mode == SourceNetworkMode.direct ||
      mode == SourceNetworkMode.directGateway;
  bool get usesProxy => proxy != null;
  String? get proxyUrl => proxy?.toString();

  @override
  bool operator ==(Object other) =>
      other is SourceNetworkRoute &&
      mode == other.mode &&
      proxy == other.proxy &&
      allowBadCertificates == other.allowBadCertificates;

  @override
  int get hashCode => Object.hash(mode, proxy, allowBadCertificates);
}

class SourceNetworkResolver {
  const SourceNetworkResolver({
    required this.isAndroid,
    required this.isVpnActive,
    required this.startGateway,
    required this.defaultRoute,
  });

  final bool isAndroid;
  final Future<bool> Function() isVpnActive;
  final Future<int> Function() startGateway;
  final SourceNetworkRoute Function(Uri? target) defaultRoute;

  Future<SourceNetworkRoute> resolve({
    required bool directConnection,
    Uri? target,
  }) async {
    if (!directConnection) return defaultRoute(target);
    if (isAndroid && await isVpnActive()) {
      return SourceNetworkRoute.gateway(await startGateway());
    }
    return const SourceNetworkRoute.direct();
  }
}
