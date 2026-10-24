import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;
import 'package:kazumi/request/config/api_endpoints.dart';

class BangumiEchResolver {
  BangumiEchResolver._();

  static final endpoint = Uri.https('dns.alidns.com', '/resolve');
  static const _hosts = {...ApiEndpoints.bangumiPublicApiHosts, 'lain.bgm.tv'};
  static const _addresses = ['172.67.134.140', '104.21.6.61', '172.67.73.67'];

  static RetryingEchResolver create(http.Client bootstrap) {
    final inner = DohEchResolver(
      client: bootstrap,
      endpoint: endpoint,
      hosts: _hosts,
      // Shared Cloudflare ECH config and pinned IPs bypass polluted Bangumi DNS.
      configDomains: {for (final host in _hosts) host: 'crypto.cloudflare.com'},
      addressOverrides: {for (final host in _hosts) host: _addresses},
    );
    return RetryingEchResolver(inner, inner.client);
  }
}

/// Retries ECH discovery once before giving up.
///
/// The DoH query is the first hop of the ECH path, so a failure there is the
/// cheapest possible thing to repeat: a rejected query returns in ~0.1 s, well
/// before any TCP or TLS work is spent. Measured on a mobile network, alidns
/// drops roughly a quarter of these queries up front (`Connection closed
/// abruptly` right after the request is sent) and a single retry recovers
/// every one of them, so the whole path stays under a second.
///
/// Only [EchException] is retried. `DohEchResolver` clears its in-flight entry
/// on failure and caches routes only on success, so the second attempt really
/// re-queries instead of replaying the rejected result.
class RetryingEchResolver implements EchResolver {
  RetryingEchResolver(this._inner, this.client);

  final EchResolver _inner;

  /// The DoH bootstrap client owned by [_inner], released with this resolver.
  final http.Client client;

  @override
  Future<EchRoute?> resolve(Uri uri) async {
    try {
      return await _inner.resolve(uri);
    } on EchException {
      return _inner.resolve(uri);
    }
  }
}
