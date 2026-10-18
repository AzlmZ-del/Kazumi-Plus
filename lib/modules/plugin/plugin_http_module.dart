class PluginHTTPItem {
  String name;
  String version;
  bool useNativePlayer;
  String author;
  int lastUpdate;
  bool antiCrawlerEnabled;

  /// Normalized URL of the repository this item was listed by.
  ///
  /// Filled in only while the catalog is aggregated from multiple
  /// repositories, so that installing or updating a rule fetches it from the
  /// repository that actually advertised it. It is *not* part of the catalog
  /// file and [fromJson] deliberately leaves it empty.
  String repositoryUrl;

  /// Display name of [repositoryUrl]'s repository, captured at aggregation time
  /// so the UI does not have to re-read settings to render a source badge.
  String repositoryLabel;

  PluginHTTPItem({
    required this.name,
    required this.version,
    required this.useNativePlayer,
    required this.author,
    required this.lastUpdate,
    this.antiCrawlerEnabled = false,
    this.repositoryUrl = '',
    this.repositoryLabel = '',
  });

  factory PluginHTTPItem.fromJson(Map<String, dynamic> json) {
    final dynamic rawConfig = json['antiCrawlerConfig'];
    final bool antiCrawlerEnabled = rawConfig is Map<String, dynamic>
        ? (rawConfig['enabled'] as bool? ?? false)
        : (json['antiCrawlerEnabled'] as bool? ?? false);
    return PluginHTTPItem(
      name: json['name'],
      version: json['version'],
      useNativePlayer: json['useNativePlayer'],
      author: json['author'],
      lastUpdate: json['lastUpdate'] ?? 0,
      antiCrawlerEnabled: antiCrawlerEnabled,
    );
  }

  /// Copy of this item tagged with the repository that advertised it.
  ///
  /// Used during catalog aggregation; the original object is left untouched so
  /// sharing an item between repositories cannot leak the wrong source.
  PluginHTTPItem withRepository({
    required String url,
    required String label,
  }) {
    return PluginHTTPItem(
      name: name,
      version: version,
      useNativePlayer: useNativePlayer,
      author: author,
      lastUpdate: lastUpdate,
      antiCrawlerEnabled: antiCrawlerEnabled,
      repositoryUrl: url,
      repositoryLabel: label,
    );
  }
}
