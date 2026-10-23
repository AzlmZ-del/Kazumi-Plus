import 'dart:convert';

import 'package:kazumi/request/config/api_endpoints.dart';

/// One rule repository the user has configured.
///
/// [url] is always stored in normalized form: absolute http(s), no embedded
/// credentials, no query or fragment, and always ending with a slash. That
/// makes the URL a stable identity key for de-duplication and lookup.
class RuleRepository {
  const RuleRepository({
    required this.url,
    this.label = '',
    this.enabled = true,
  });

  /// Normalized repository directory URL, always ending with `/`.
  final String url;

  /// User-chosen display name. Empty means "fall back to the host name".
  final String label;

  final bool enabled;

  bool get isOfficial => url == RuleRepositoryList.officialUrl;

  /// The built-in repository that ships alongside the official one.
  bool get isPersonal => url == RuleRepositoryList.personalUrl;

  /// Built-in repositories are always present and can only be switched off.
  bool get isBuiltIn => isOfficial || isPersonal;

  /// Display name of a built-in repository the user has not renamed.
  ///
  /// Kept out of [displayLabel] so that failure messages and other places that
  /// only know the address keep using the plain host/repository name.
  String? get builtInLabel => RuleRepositoryList.builtInLabelOf(url);

  /// Host portion of [url], used as the compact subtitle and as the last-resort
  /// display name.
  String get hostLabel {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host;
  }

  /// Repository name read out of the URL path.
  ///
  /// Repository hosts put the name a fixed number of segments in
  /// (`/<owner>/<repo>/<ref>/...` on GitHub's raw host, for instance), so those
  /// are handled by [_repositoryNameIndex]. Any other layout falls back to the
  /// last segment that is not a ref name, then to the host when the URL has no
  /// path at all.
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

    // Unknown layout: the tail is usually the directory the user meant, unless
    // a deep link left a ref such as `main` behind.
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

  /// Known branch and tag names that can appear as a path segment.
  ///
  /// Only used to skip a segment when a URL layout is unrecognized, so the list
  /// stays deliberately short — a repository actually named `main` is far
  /// rarer than a ref segment, and the known hosts below never consult it.
  static const Set<String> _refNames = {
    'main',
    'master',
    'develop',
    'dev',
    'gh-pages',
    'latest',
  };

  /// Index of the repository-name segment for [host], or null when the host has
  /// no known layout.
  ///
  /// GitHub's raw host serves `/<owner>/<repo>/<ref>/<path>`; GitLab's raw host
  /// serves `/<owner>/<repo>/-/raw/<ref>/<path>`. Everything else is layout-free
  /// and goes through the generic tail scan.
  static int? _repositoryNameIndex(String host, int segmentCount) {
    if (segmentCount < 2) {
      return null;
    }
    if (host == 'raw.githubusercontent.com' || host == 'raw.gitmirror.com') {
      return 1;
    }
    if (host == 'raw.gitcode.com') {
      // `gh_mirrors/ka/KazumiRules/raw/main/`
      return segmentCount >= 3 ? 2 : null;
    }
    if (host == 'gitlab.com' || host.endsWith('.gitlab.com')) {
      return 1;
    }
    // jsDelivr: `/gh/<owner>/<repo>@<ref>/<path>` and `/gl/<owner>/<repo>@..`.
    if (host == 'cdn.jsdelivr.net' || host == 'fastly.jsdelivr.net') {
      return segmentCount >= 3 ? 2 : null;
    }
    return null;
  }

  /// Drops a `@<ref>` suffix that some hosts fold into the name segment.
  static String _stripRefSuffix(String segment) {
    final at = segment.indexOf('@');
    return at > 0 ? segment.substring(0, at) : segment;
  }
}

/// Persisted as a single JSON string under `SettingsKeys.ruleRepositories`.
///
/// An empty string means "never configured" and decodes to the built-in
/// defaults, so upgrading users keep the current single-repository behavior
/// without writing anything to disk.
class RuleRepositoryList {
  const RuleRepositoryList._();

  /// The official repository address. Kept in [ApiEndpoints] because the
  /// mirror interceptor still keys off the same constant.
  static String get officialUrl => ApiEndpoints.pluginShop;

  /// The second built-in repository, kept next to the official one.
  static String get personalUrl => ApiEndpoints.personalPluginShop;

  /// Short name of a built-in repository address, null for anything else.
  ///
  /// Takes an address rather than a [RuleRepository] because catalog entries
  /// only carry the URL they came from.
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

  /// Decodes the persisted value.
  ///
  /// Decoding is deliberately lenient: a single corrupt entry is skipped
  /// instead of discarding the whole configuration, because otherwise one bad
  /// row would silently reset every repository the user added.
  ///
  /// The built-in repositories are always present and always first; see the
  /// "official is fixed at index 0" invariant in the design document.
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

  /// Restores the "built-ins first, never missing" invariant.
  ///
  /// The official repository is pinned at index 0 because the update path falls
  /// back to it, and the personal repository sits right behind it. Both come
  /// back when the stored value has lost them, so an older configuration picks
  /// them up without asking the user to add anything.
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
      // A missing or non-boolean flag falls back to "enabled" rather than
      // silently hiding a repository the user can still see in the list.
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
