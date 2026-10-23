import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/network/acceleration_mode.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Rule repository acceleration.
///
/// gh-proxy and ghfast are prefix proxies: the whole original URL is appended.
/// GitCode only mirrors the official repository by path, so the personal
/// repository stays on gh-proxy no matter which mode is picked.
enum RulesMirror implements AccelerationMode {
  ghProxy,
  ghfast,
  gitcode,
  direct;

  static RulesMirror get current =>
      values.asNameMap()[GStorage.getSetting(SettingsKeys.rulesMirror)] ??
      (GStorage.getSetting(SettingsKeys.enableGitProxy) ? ghProxy : direct);

  @override
  String get label => switch (this) {
    ghProxy => 'gh-proxy',
    ghfast => 'ghfast',
    gitcode => 'GitCode',
    direct => 'GitHub',
  };

  @override
  String get description => switch (this) {
    ghProxy => '默认镜像',
    ghfast => '备用镜像',
    gitcode => '国内镜像',
    direct => '直连访问',
  };

  /// Rewrites [url] onto this mirror, or returns null when it stays untouched.
  String? map(String url) {
    final official = url.startsWith(ApiEndpoints.pluginShop);
    final personal = url.startsWith(ApiEndpoints.personalPluginShop);
    if (!official && !personal) {
      return null;
    }
    switch (this) {
      case direct:
        return null;
      case ghProxy:
        return '${ApiEndpoints.ghProxyMirror}$url';
      case ghfast:
        return '${ApiEndpoints.ghfastMirror}$url';
      case gitcode:
        return official
            ? '${ApiEndpoints.gitcodeMirror}'
                  '${url.substring(ApiEndpoints.pluginShop.length)}'
            : '${ApiEndpoints.ghProxyMirror}$url';
    }
  }
}
