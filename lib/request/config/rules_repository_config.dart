import 'package:kazumi/modules/plugin/rule_repository.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Normalizes and validates user-supplied rule repository addresses, and
/// supplies the URL builders used by the catalog / single-rule fetchers.
///
/// Everything here is pure so it can be unit-tested without storage.
class RulesRepositoryConfig {
  const RulesRepositoryConfig._();

  /// Repository directory URLs whose host must be rejected outright.
  ///
  /// `github.com` is blocked because those URLs point at a *web page*, not raw
  /// content; pasting one can never work and the failure surfaces as a
  /// confusing parse error far from the input. `raw.githubusercontent.com` is
  /// a different host and stays allowed (it is the official repository).
  static const Set<String> _rejectedHosts = {'github.com', 'www.github.com'};

  /// Largest accepted repository address length. Long enough for any real CDN
  /// path, short enough to stay readable in the management list.
  static const int maxUrlLength = 2048;

  /// Normalizes [input] into a repository directory URL.
  ///
  /// The result always ends with `/`, never carries credentials, query or
  /// fragment, and points at a directory rather than a file.
  ///
  /// Throws [FormatException] with a user-facing Chinese message.
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

    // Trailing slash on the raw path decides whether the last segment is a
    // directory or a file candidate. `Uri.pathSegments` alone cannot tell
    // `.../rules/index.json/` from `.../rules/index.json`.
    final hadTrailingSlash = uri.path.endsWith('/');
    final segments = <String>[
      for (final segment in uri.pathSegments)
        if (segment.isNotEmpty) segment,
    ];

    if (segments.isEmpty) {
      // A bare origin such as `https://example.com` is a valid root repository.
      return _rebuild(uri, const <String>[]);
    }

    final last = segments.last;
    if (_looksLikeFileName(last)) {
      if (!hadTrailingSlash) {
        // The user pasted a file URL: peel the file off and keep the directory.
        segments.removeLast();
        return _rebuild(uri, segments);
      }
      // A dot inside the final segment is fine when the path ends with `/`,
      // e.g. jsDelivr version tags such as `.../gh/user/Rules@1.2.0/`.
    }

    return _rebuild(uri, segments);
  }

  /// Whether [segment] looks like a file name (as opposed to a directory).
  ///
  /// A leading dot (`.hidden`) is a directory, not a file, so only dots after
  /// the first character count.
  static bool _looksLikeFileName(String segment) {
    final dot = segment.indexOf('.', 1);
    return dot > 0 && dot < segment.length - 1;
  }

  /// Rebuilds [uri] from decoded path segments, dropping credentials, query and
  /// fragment, and always ending the path with `/`.
  ///
  /// Segments are passed decoded and re-encoded here, which is why the caller
  /// must use [Uri.pathSegments] rather than slicing the encoded `uri.path`.
  static String _rebuild(Uri uri, List<String> segments) {
    // `Uri.replace(pathSegments: [''])` yields an empty path instead of `/`,
    // so the root case needs an explicit path.
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

  /// Builds the catalog URL for a normalized repository directory.
  static String catalogUri(String repositoryUrl) => '${_withSlash(repositoryUrl)}index.json';

  /// Builds the single-rule URL for a normalized repository directory.
  static String ruleUri(String repositoryUrl, String name) =>
      '${_withSlash(repositoryUrl)}$name.json';

  static String _withSlash(String url) => url.endsWith('/') ? url : '$url/';

  /// Reads the configured repositories from storage.
  ///
  /// Never throws: a corrupt value decodes to the built-in defaults.
  static List<RuleRepository> repositories() {
    return RuleRepositoryList.decode(
      GStorage.getSetting(SettingsKeys.ruleRepositories),
    );
  }

  /// Enabled repositories in list order, i.e. the priority order used to
  /// resolve same-named rules.
  static List<RuleRepository> enabledRepositories() {
    return [
      for (final repository in repositories())
        if (repository.enabled) repository,
    ];
  }

  /// Persists [repositories] verbatim.
  static Future<void> save(List<RuleRepository> repositories) {
    return GStorage.putSetting(
      SettingsKeys.ruleRepositories,
      RuleRepositoryList.encode(repositories),
    );
  }

  /// Appends [repository] to the stored list, or throws [FormatException] when
  /// an entry with the same normalized URL already exists.
  static Future<List<RuleRepository>> add(RuleRepository repository) async {
    final current = repositories();
    if (current.any((existing) => existing.url == repository.url)) {
      throw const FormatException('该仓库已存在');
    }
    final updated = [...current, repository];
    await save(updated);
    return updated;
  }

  /// Replaces the entry whose `url` equals [originalUrl], rejecting a rename to
  /// a URL that is already taken by a different entry.
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

  /// Removes the entry at [url]. Built-in repositories cannot be removed.
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
