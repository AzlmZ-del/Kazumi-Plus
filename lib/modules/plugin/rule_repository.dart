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

  /// Host portion of [url], used as the compact subtitle and as the fallback
  /// display name.
  String get hostLabel {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host;
  }

  String get displayLabel => label.isNotEmpty ? label : hostLabel;

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

  static List<RuleRepository> defaults() => <RuleRepository>[
    RuleRepository(url: officialUrl),
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
  /// The official repository is always present and always first; see the
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

    return _withOfficialFirst(repositories);
  }

  /// Restores the "official first, never missing" invariant.
  static List<RuleRepository> _withOfficialFirst(
    List<RuleRepository> repositories,
  ) {
    final officialIndex = repositories.indexWhere((repo) => repo.isOfficial);
    if (officialIndex == 0) {
      return repositories;
    }
    if (officialIndex < 0) {
      return <RuleRepository>[
        RuleRepository(url: officialUrl),
        ...repositories,
      ];
    }
    final reordered = <RuleRepository>[...repositories];
    final official = reordered.removeAt(officialIndex);
    reordered.insert(0, official);
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
