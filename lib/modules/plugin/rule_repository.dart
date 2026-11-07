import 'dart:convert';

import 'package:kazumi/request/config/api_endpoints.dart';

/// 用户配置的一条规则仓库。
///
/// [url] 恒为规范化形式：绝对 http(s) 地址、不含内嵌凭据、不含 query 与
/// fragment、且以斜杠结尾。这样 URL 才能当作稳定标识用于去重与查找。
///
/// 规范化发生在写入路径上（`RulesRepositoryConfig.baseUri`），本类假定它已跑过。
class RuleRepository {
  const RuleRepository({
    required this.url,
    this.label = '',
    this.enabled = true,
  });

  /// 规范化后的仓库目录 URL，恒以 `/` 结尾。
  final String url;

  /// 用户自定义的显示名。为空表示「退回主机名」。
  final String label;

  final bool enabled;

  bool get isOfficial => url == RuleRepositoryList.officialUrl;

  /// 与官方仓库并列内置的个人仓库。
  bool get isPersonal => url == RuleRepositoryList.personalUrl;

  /// 内置仓库恒存在，只能关闭、不能删除。
  bool get isBuiltIn => isOfficial || isPersonal;

  /// [url] 的主机部分，用作紧凑副标题，也是最后的兜底显示名。
  String get hostLabel {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host;
  }

  /// 从 URL 路径里读出的仓库名。
  ///
  /// 各仓库托管把名字放在固定段位上（如 GitHub raw 的
  /// `/<owner>/<repo>/<ref>/...`），这类交给 [_repositoryNameIndex] 处理。
  /// 其它布局退回「最后一个不是 ref 名的段」，URL 完全没有路径时退回主机名。
  String get inferredLabel {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return url;
    }
    final segments = <String>[
      for (final segment in uri.pathSegments)
        if (segment.isNotEmpty) segment,
    ];
    if (segments.isEmpty) {
      return hostLabel;
    }

    final index = _repositoryNameIndex(uri.host.toLowerCase(), segments.length);
    if (index != null) {
      final name = _stripRefSuffix(segments[index]);
      if (name.isNotEmpty) {
        return name;
      }
    }

    // 布局无法识别：末尾通常就是用户想要的那个目录，
    // 除非深链在末尾留下了一个类似 `main` 的 ref。
    for (var i = segments.length - 1; i >= 0; i--) {
      final segment = segments[i];
      if (_refNames.contains(segment.toLowerCase())) {
        continue;
      }
      return segment;
    }
    return hostLabel;
  }

  String get displayLabel => label.isNotEmpty ? label : inferredLabel;

  RuleRepository copyWith({String? label, bool? enabled}) {
    return RuleRepository(
      url: url,
      label: label ?? this.label,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    'label': label,
    'enabled': enabled,
  };

  @override
  bool operator ==(Object other) {
    return other is RuleRepository &&
        other.url == url &&
        other.label == label &&
        other.enabled == enabled;
  }

  @override
  int get hashCode => Object.hash(url, label, enabled);

  @override
  String toString() => 'RuleRepository($url, label: $label, enabled: $enabled)';

  /// 可能出现在路径段里的已知分支名与标签名。
  ///
  /// 只在 URL 布局无法识别时用来跳过一个段，所以列表刻意保持很短——
  /// 真有仓库叫 `main` 的概率远低于这里是个 ref 段，且下面列出的已知
  /// 主机根本不查这个集合。
  static const Set<String> _refNames = {
    'main',
    'master',
    'develop',
    'dev',
    'gh-pages',
    'latest',
  };

  /// [host] 上仓库名所在段的索引；主机布局未知时返回 null。
  ///
  /// GitHub raw 是 `/<owner>/<repo>/<ref>/<path>`；GitLab raw 是
  /// `/<owner>/<repo>/-/raw/<ref>/<path>`。其余主机没有固定布局，
  /// 走通用的尾部扫描。
  static int? _repositoryNameIndex(String host, int segmentCount) {
    if (segmentCount < 2) {
      return null;
    }
    if (host == 'raw.githubusercontent.com' || host == 'raw.gitmirror.com') {
      return 1;
    }
    if (host == 'raw.gitcode.com') {
      // 形如 `gh_mirrors/ka/KazumiRules/raw/main/` 的镜像地址。
      return segmentCount >= 3 ? 2 : null;
    }
    if (host == 'gitlab.com' || host.endsWith('.gitlab.com')) {
      return 1;
    }
    // jsDelivr 形式：`/gh/<owner>/<repo>@<ref>/<path>` 与 `/gl/<owner>/<repo>@..`。
    if (host == 'cdn.jsdelivr.net' || host == 'fastly.jsdelivr.net') {
      return segmentCount >= 3 ? 2 : null;
    }
    return null;
  }

  /// 去掉某些主机会并进名字段里的 `@<ref>` 后缀。
  static String _stripRefSuffix(String segment) {
    final at = segment.indexOf('@');
    return at > 0 ? segment.substring(0, at) : segment;
  }
}

/// 以单条 JSON 字符串存在 `SettingsKeys.ruleRepositories` 下。
///
/// 空串表示「从未配置过」，解码得到内置默认值（官方 + 个人），
/// 老用户升级后无需写盘就能拿到新增的内置仓库。
class RuleRepositoryList {
  const RuleRepositoryList._();

  /// 官方仓库地址。放在 [ApiEndpoints] 里，因为镜像拦截器仍以同一个常量为键。
  static String get officialUrl => ApiEndpoints.pluginShop;

  /// 第二个内置仓库，紧挨官方仓库。
  static String get personalUrl => ApiEndpoints.personalPluginShop;

  /// 内置仓库地址对应的短名，其它地址返回 null。
  ///
  /// 收地址而不是 [RuleRepository]，因为索引条目只带它来源的那个 URL。
  static String? builtInLabelOf(String url) {
    if (url == officialUrl) {
      return '官方仓库';
    }
    if (url == personalUrl) {
      return '个人仓库';
    }
    return null;
  }

  static List<RuleRepository> defaults() => <RuleRepository>[
    RuleRepository(url: officialUrl),
    RuleRepository(url: personalUrl),
  ];

  static String encode(List<RuleRepository> repositories) {
    return jsonEncode([
      for (final repository in repositories) repository.toJson(),
    ]);
  }

  /// 解码持久化的值。
  ///
  /// 解码刻意宽容：单条损坏的条目跳过，而不是整份配置作废——否则一行坏数据
  /// 就会把用户加过的所有仓库悄悄重置掉。
  ///
  /// 内置仓库恒存在且恒在最前：官方在索引 0、个人在索引 1，见 [_withBuiltIns]。
  static List<RuleRepository> decode(String raw) {
    if (raw.trim().isEmpty) {
      return defaults();
    }

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return defaults();
    }
    if (decoded is! List) {
      return defaults();
    }

    final repositories = <RuleRepository>[];
    final seenUrls = <String>{};
    for (final entry in decoded) {
      final repository = _decodeEntry(entry);
      if (repository == null) {
        continue;
      }
      if (!seenUrls.add(repository.url)) {
        continue;
      }
      repositories.add(repository);
    }

    if (repositories.isEmpty) {
      return defaults();
    }

    return _withBuiltIns(repositories);
  }

  /// 恢复「内置仓库在最前、且永不缺失」的不变量。
  ///
  /// 官方仓库固定在索引 0，因为更新路径会退回它；个人仓库紧随其后。
  /// 存储值里丢了它们时都会补回来，老配置因此不必让用户手动添加。
  static List<RuleRepository> _withBuiltIns(
    List<RuleRepository> repositories,
  ) {
    final reordered = <RuleRepository>[...repositories];

    final officialIndex = reordered.indexWhere((repo) => repo.isOfficial);
    if (officialIndex < 0) {
      reordered.insert(0, RuleRepository(url: officialUrl));
    } else if (officialIndex != 0) {
      reordered.insert(0, reordered.removeAt(officialIndex));
    }

    final personalIndex = reordered.indexWhere((repo) => repo.isPersonal);
    if (personalIndex < 0) {
      reordered.insert(1, RuleRepository(url: personalUrl));
    } else if (personalIndex != 1) {
      reordered.insert(1, reordered.removeAt(personalIndex));
    }

    return reordered;
  }

  static RuleRepository? _decodeEntry(Object? entry) {
    if (entry is! Map) {
      return null;
    }
    final Object? rawUrl = entry['url'];
    if (rawUrl is! String || !_isAbsoluteHttpUrl(rawUrl)) {
      return null;
    }
    final Object? rawLabel = entry['label'];
    final Object? rawEnabled = entry['enabled'];
    return RuleRepository(
      url: rawUrl,
      label: rawLabel is String ? rawLabel : '',
      // 标志缺失或不是布尔值时，一律按「已启用」处理，
      // 而不是把用户在列表里明明还看得见的仓库悄悄藏起来。
      enabled: rawEnabled is bool ? rawEnabled : true,
    );
  }

  static bool _isAbsoluteHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return false;
    }
    return uri.scheme == 'http' || uri.scheme == 'https';
  }
}
