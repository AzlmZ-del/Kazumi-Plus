import 'package:kazumi/modules/plugin/rule_repository.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 规范化并校验用户填写的规则仓库地址，
/// 同时提供目录与单规则拉取所用的 URL 构造函数。
///
/// 这里全是纯函数，单元测试无需碰存储。
class RulesRepositoryConfig {
  const RulesRepositoryConfig._();

  /// 主机名必须直接拒掉的仓库目录地址。
  ///
  /// 屏蔽 `github.com` 是因为那类地址指向的是**网页**而不是原始内容，
  /// 粘进来永远不可能成功，而且报错会变成一段与输入相隔很远、
  /// 让人摸不着头脑的解析错误。`raw.githubusercontent.com` 是另一个主机，
  /// 依然放行（官方仓库就在那儿）。
  static const Set<String> _rejectedHosts = {'github.com', 'www.github.com'};

  /// 允许的最长仓库地址。足够容纳任何真实 CDN 路径，
  /// 又短到在管理列表里还能看清。
  static const int maxUrlLength = 2048;

  /// 把 [input] 规范化成仓库目录 URL。
  ///
  /// 结果恒以 `/` 结尾，不带凭据、query 或 fragment，且指向目录而非文件。
  ///
  /// 失败时抛 [FormatException]，消息是面向用户的中文。
  static String baseUri(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('请填写仓库地址');
    }
    if (trimmed.length > maxUrlLength) {
      throw const FormatException('仓库地址过长');
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      throw const FormatException('地址格式不正确');
    }
    if (!uri.hasScheme) {
      throw const FormatException('地址需要以 http:// 或 https:// 开头');
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw const FormatException('只支持 http:// 和 https:// 地址');
    }
    if (uri.host.isEmpty) {
      throw const FormatException('地址缺少域名');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException('地址不能包含用户名或密码');
    }
    if (uri.hasQuery) {
      throw const FormatException('地址不能包含查询参数（? 之后的内容）');
    }
    if (uri.hasFragment) {
      throw const FormatException('地址不能包含锚点（# 之后的内容）');
    }
    final host = uri.host.toLowerCase();
    if (_rejectedHosts.contains(host)) {
      throw const FormatException(
        'github.com 页面地址无法直接使用，请改用 raw.githubusercontent.com 等原始内容地址',
      );
    }

    // 原始路径末尾有没有斜杠，决定了最后一段是目录还是文件候选。
    // 单看 `Uri.pathSegments` 分不出
    // `.../rules/index.json/` 与 `.../rules/index.json`。
    final hadTrailingSlash = uri.path.endsWith('/');
    final segments = <String>[
      for (final segment in uri.pathSegments)
        if (segment.isNotEmpty) segment,
    ];

    if (segments.isEmpty) {
      // 像 `https://example.com` 这样的裸域名也是合法的根仓库。
      return _rebuild(uri, const <String>[]);
    }

    final last = segments.last;
    if (_looksLikeFileName(last)) {
      if (!hadTrailingSlash) {
        // 用户粘的是文件地址：把文件名剥掉，只留目录。
        segments.removeLast();
        return _rebuild(uri, segments);
      }
      // 路径以 `/` 结尾时，最后一段里带点也没问题，
      // 比如 jsDelivr 的版本标签 `.../gh/user/Rules@1.2.0/`。
    }

    return _rebuild(uri, segments);
  }

  /// 判断 [segment] 看起来是不是文件名（而不是目录名）。
  ///
  /// 开头的点（`.hidden`）算目录不算文件，所以只数第一个字符之后的点。
  static bool _looksLikeFileName(String segment) {
    final dot = segment.indexOf('.', 1);
    return dot > 0 && dot < segment.length - 1;
  }

  /// 用解码后的路径段重建 [uri]，丢掉凭据、query 与 fragment，
  /// 并让路径恒以 `/` 结尾。
  ///
  /// 传进来的是解码后的段，在这里重新编码；所以调用方必须用
  /// [Uri.pathSegments]，而不是去切已编码的 `uri.path`。
  static String _rebuild(Uri uri, List<String> segments) {
    // `Uri.replace(pathSegments: [''])` 得到的是空路径而不是 `/`，
    // 所以根路径这种情形要显式指定 path。
    final rebuilt = uri.replace(
      scheme: uri.scheme.toLowerCase(),
      userInfo: '',
      query: null,
      fragment: null,
      path: segments.isEmpty ? '/' : null,
      pathSegments: segments.isEmpty ? null : [...segments, ''],
    );
    return rebuilt.toString();
  }

  /// 为规范化后的仓库目录拼出目录索引 URL。
  static String catalogUri(String repositoryUrl) => '${_withSlash(repositoryUrl)}index.json';

  /// 为规范化后的仓库目录拼出单条规则的 URL。
  static String ruleUri(String repositoryUrl, String name) =>
      '${_withSlash(repositoryUrl)}$name.json';

  static String _withSlash(String url) => url.endsWith('/') ? url : '$url/';

  /// 从存储里读出已配置的仓库。
  ///
  /// 永不抛异常：值损坏时解码成内置默认值。
  static List<RuleRepository> repositories() {
    return RuleRepositoryList.decode(
      GStorage.getSetting(SettingsKeys.ruleRepositories),
    );
  }

  /// 按列表顺序排列的已启用仓库，也就是解析同名规则时用的优先级顺序。
  static List<RuleRepository> enabledRepositories() {
    return [
      for (final repository in repositories())
        if (repository.enabled) repository,
    ];
  }

  /// 把 [repositories] 原样落盘。
  static Future<void> save(List<RuleRepository> repositories) {
    return GStorage.putSetting(
      SettingsKeys.ruleRepositories,
      RuleRepositoryList.encode(repositories),
    );
  }

  /// 把 [repository] 追加到存储列表；若已有规范化后 URL 相同的条目，
  /// 则抛 [FormatException]。
  static Future<List<RuleRepository>> add(RuleRepository repository) async {
    final current = repositories();
    if (current.any((existing) => existing.url == repository.url)) {
      throw const FormatException('该仓库已存在');
    }
    final updated = [...current, repository];
    await save(updated);
    return updated;
  }

  /// 替换 `url` 等于 [originalUrl] 的那一条；
  /// 若改后的 URL 已被另一条占用，则拒绝。
  static Future<List<RuleRepository>> replace(
    String originalUrl,
    RuleRepository updated,
  ) async {
    final current = repositories();
    final index = current.indexWhere((existing) => existing.url == originalUrl);
    if (index < 0) {
      throw const FormatException('该仓库不存在');
    }
    if (updated.url != originalUrl &&
        current.any((existing) => existing.url == updated.url)) {
      throw const FormatException('该仓库已存在');
    }
    final next = [...current]..[index] = updated;
    await save(next);
    return next;
  }

  /// 删除 [url] 对应的条目。内置仓库不能删除。
  static Future<List<RuleRepository>> remove(String url) async {
    final current = repositories();
    for (final repo in current) {
      if (repo.url != url || !repo.isBuiltIn) {
        continue;
      }
      throw FormatException(
        repo.isOfficial ? '官方仓库不能删除，可以关闭它' : '个人仓库不能删除，可以关闭它',
      );
    }
    final next = [
      for (final existing in current)
        if (existing.url != url) existing,
    ];
    await save(next);
    return next;
  }
}
