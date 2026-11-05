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

/// ECH 发现阶段的重试包装。
///
/// DoH 查询是 ECH 链路的第一跳，失败后重试成本最低（被拒的查询约 0.1s 返回，
/// 还没花任何 TCP/TLS 时间）。实测 alidns 会直接丢掉约四分之一的查询，
/// 这里最多重试 [maxAttempts] 次，带指数退避。
///
/// 只重试 [EchException]。`DohEchResolver` 失败时会清掉 in-flight 记录、
/// 只缓存成功结果，所以每次重试都是真正重新查询。
class RetryingEchResolver implements EchResolver {
  RetryingEchResolver(this._inner, this.client);

  /// 总尝试次数（含首次）。
  static const int maxAttempts = 3;

  /// 首次重试前的等待，之后每次翻倍。
  static const Duration baseDelay = Duration(milliseconds: 100);

  final EchResolver _inner;

  /// The DoH bootstrap client owned by [_inner], released with this resolver.
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
