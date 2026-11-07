import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/network/acceleration_mode.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 规则仓库加速。
///
/// gh-proxy 与 ghfast 是前缀代理：把完整原始 URL 接在后面即可。
/// GitCode 只按路径镜像官方仓库，所以无论选哪种模式，
/// 个人仓库都还是走 gh-proxy。
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

  /// 把 [url] 改写到本镜像上；不需要改写时返回 null。
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
