import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;
import 'package:kazumi/request/config/api_endpoints.dart';

class BangumiEchResolver {
  BangumiEchResolver._();

  static final endpoint = Uri.https('dns.alidns.com', '/resolve');
  static const _hosts = {...ApiEndpoints.bangumiPublicApiHosts, 'lain.bgm.tv'};
  static const _addresses = ['172.67.134.140', '104.21.6.61', '172.67.73.67'];

  static RetryingEchResolver create(
    http.Client bootstrap, {
    Set<String> additionalHosts = const {},
  }) {
    final hosts = {..._hosts, ...additionalHosts};
    final inner = DohEchResolver(
      client: bootstrap,
      endpoint: endpoint,
      hosts: hosts,
      // Shared Cloudflare ECH config and pinned IPs bypass polluted DNS.
      configDomains: {for (final host in hosts) host: 'crypto.cloudflare.com'},
      addressOverrides: {for (final host in hosts) host: _addresses},
    );
    return RetryingEchResolver(inner, inner.client);
  }
}

/// Retry wrapper around ECH discovery.
///
/// The DoH lookup is the first hop of the ECH chain and the cheapest to retry:
/// alidns drops roughly a quarter of queries. Up to [maxAttempts] attempts,
/// each with exponential backoff.
///
/// Only [EchException] is retried. `DohEchResolver` clears in-flight records on
/// failure and caches only successes, so every retry is a real re-query.
class RetryingEchResolver implements EchResolver {
  RetryingEchResolver(this._inner, this.client);

  /// Total attempts, including the first.
  static const int maxAttempts = 3;

  /// Delay before the first retry; doubles on each subsequent attempt.
  static const Duration baseDelay = Duration(milliseconds: 100);

  final EchResolver _inner;

  /// DoH bootstrap client owned by [_inner] and released with this resolver.
  final http.Client client;

  @override
  Future<EchRoute?> resolve(Uri uri) async {
    var delay = baseDelay;
    for (var attempt = 1; ; attempt++) {
      try {
        return await _inner.resolve(uri);
      } on EchException {
        if (attempt >= maxAttempts) rethrow;
        await Future.delayed(delay);
        delay *= 2;
      }
    }
  }
}
