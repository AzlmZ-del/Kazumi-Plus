import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/network/acceleration_mode.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 规则仓库加速。
///
/// 前缀代理把完整原始 URL 接在镜像后面；jsDelivr 是路径式镜像，要把
/// GitHub raw 改写成 `gh/<owner>/<repo>@<ref>/<path>`；GitCode 只镜像官方仓库。
/// 对无法镜像的地址一律返回 null，调用方据此判断「这一档不生效」。
enum RulesMirror implements AccelerationMode {
  direct,
  gitcode,
  ghProxy,
  ghfast,
  ghProxyCom,
  ghProxyImciel,
  ghProxyNet,
  ghProxyCn,
  jsDelivr,
  jsDelivrGcore;

  /// 当前档位；从未配置过时默认直连（GitHub）。
  ///
  /// 不再回退到旧版 `enableGitProxy` 开关：它默认为真，会让新装用户一上手
  /// 就走 cdn.gh-proxy.org，而那个节点实测长期 500，打开规则列表就报错。
  static RulesMirror get current =>
      values.asNameMap()[GStorage.getSetting(SettingsKeys.rulesMirror)] ??
      direct;

  @override
  String get label => switch (this) {
    ghProxy => 'gh-proxy',
    ghfast => 'ghfast',
    ghProxyCom => 'gh-proxy.com',
    ghProxyImciel => 'ghproxy.imciel',
    ghProxyNet => 'ghproxy.net',
    ghProxyCn => 'ghproxy.cn',
    jsDelivr => 'jsDelivr',
    jsDelivrGcore => 'jsDelivr Gcore',
    gitcode => 'GitCode',
    direct => 'GitHub',
  };

  @override
  String get description => switch (this) {
    ghProxy => '备用镜像',
    ghfast => '备用镜像',
    ghProxyCom => '备用镜像',
    ghProxyImciel => '备用镜像',
    ghProxyNet => '备用镜像',
    ghProxyCn => '备用镜像',
    jsDelivr => '国内镜像',
    jsDelivrGcore => '国内镜像',
    gitcode => '国内镜像',
    direct => '直连访问',
  };

  /// 该档位的探测超时。
  ///
  /// 慢镜像（ghproxy.net / ghproxy.cn）实测要 1~12 秒，用统一的短超时会把它们
  /// 判成「不可用」，掩盖真实延迟；这里按档位放宽，让界面给出实际毫秒数。
  Duration get probeTimeout => switch (this) {
    ghProxyCn => const Duration(seconds: 15),
    ghProxyNet => const Duration(seconds: 8),
    _ => const Duration(milliseconds: 1500),
  };

  /// 前缀式代理：把完整 URL 拼在镜像后面即可。
  bool get _isPrefix => switch (this) {
    ghProxy ||
    ghfast ||
    ghProxyCom ||
    ghProxyImciel ||
    ghProxyNet ||
    ghProxyCn => true,
    _ => false,
  };

  /// 前缀式镜像的拼接前缀；路径式镜像与直连返回 null。
  ///
  /// 给非规则仓库的 GitHub raw 地址用（例如每日放送的 CSV）：
  /// 它们不走 [map]，但仍能享受前缀镜像。
  String? get prefixOrNull => _isPrefix && _prefix.isNotEmpty ? _prefix : null;

  /// 路径式镜像：只认 GitHub raw 地址，需要重排路径。
  bool get _isJsDelivr => this == jsDelivr || this == jsDelivrGcore;

  /// 该档位对内置仓库是否真正生效。
  ///
  /// GitCode 只镜像官方仓库；用来说明「这一档对当前仓库并不生效」，
  /// 避免用户误以为在用它加速个人仓库。
  bool get mirrorsOnlyOfficial => this == gitcode;

  /// 本档位是否真的在加速 [url]：返回本档位自己的前缀则说明生效。
  ///
  /// 用来区分「改写了」和「回退到别的档位」——后者测出来的不是本档位的速度。
  bool appliesTo(String url) {
    final mapped = map(url);
    if (mapped == null) {
      return false;
    }
    if (_isPrefix) {
      return mapped.startsWith(_prefix);
    }
    if (_isJsDelivr) {
      return mapped.startsWith(_jsDelivrBase);
    }
    return mapped.startsWith(ApiEndpoints.gitcodeMirror);
  }

  String get _prefix => switch (this) {
    ghProxy => ApiEndpoints.ghProxyMirror,
    ghfast => ApiEndpoints.ghfastMirror,
    ghProxyCom => ApiEndpoints.ghProxyComMirror,
    ghProxyImciel => ApiEndpoints.ghProxyImcielMirror,
    ghProxyNet => ApiEndpoints.ghProxyNetMirror,
    ghProxyCn => ApiEndpoints.ghProxyCnMirror,
    _ => '',
  };

  String get _jsDelivrBase => this == jsDelivrGcore
      ? ApiEndpoints.jsDelivrGcoreMirror
      : ApiEndpoints.jsDelivrMirror;

  /// 把 [url] 改写到本镜像上；不需要改写或本档位不适用时返回 null。
  String? map(String url) {
    final official = url.startsWith(ApiEndpoints.pluginShop);
    final personal = url.startsWith(ApiEndpoints.personalPluginShop);
    if (!official && !personal) {
      return null;
    }
    if (this == direct) {
      return null;
    }
    if (_isPrefix) {
      return '$_prefix$url';
    }
    if (_isJsDelivr) {
      return _mapJsDelivr(url);
    }
    // gitcode：官方仓库走 GitCode，其余回退 gh-proxy。
    return official
        ? '${ApiEndpoints.gitcodeMirror}'
              '${url.substring(ApiEndpoints.pluginShop.length)}'
        : '${ApiEndpoints.ghProxyMirror}$url';
  }

  /// 把 `raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>` 改写成
  /// jsDelivr 的 `gh/<owner>/<repo>@<ref>/<path>`。
  ///
  /// 基准取整条 raw 域名的前缀，不能取 `pluginShop`：后者已经吃掉了
  /// `owner/repo/ref`，再按它截断就只剩文件名，段数永远不够。
  String? _mapJsDelivr(String url) {
    const rawPrefix = ApiEndpoints.githubRawPrefix;
    if (!url.startsWith(rawPrefix)) {
      return null;
    }
    final segments = url.substring(rawPrefix.length).split('/');
    // 至少要有 owner/repo/ref/path 四段才有得改。
    if (segments.length < 4) {
      return null;
    }
    final owner = segments[0];
    final repo = segments[1];
    final ref = segments[2];
    final rest = segments.skip(3).join('/');
    return '$_jsDelivrBase$owner/$repo@$ref/$rest';
  }
}
