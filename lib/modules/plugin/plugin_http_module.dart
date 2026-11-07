class PluginHTTPItem {
  String name;
  String version;
  bool useNativePlayer;
  String author;
  int lastUpdate;

  /// 规则级「直连」声明，来自 index.json 条目（老索引无此键时为 false）。
  bool directConnection;

  /// 规则类型（API / XPath / 混合），由规则文件的 `api` 键在生成索引时翻好。
  ///
  /// 老仓库的 index.json 没有这个字段，[fromJson] 会留空串，界面据此不画标签。
  String type;

  /// 该条目被列出的仓库 URL（已规范化）。
  ///
  /// 只在多仓库聚合时填充：安装或更新规则要去它实际所属的仓库取。
  /// 它不属于索引文件本身，[fromJson] 刻意留空。
  String repositoryUrl;

  /// [repositoryUrl] 对应仓库的显示名，聚合时一并捕获，
  /// 让界面画来源标签时不必再读设置。
  String repositoryLabel;

  PluginHTTPItem({
    required this.name,
    required this.version,
    required this.useNativePlayer,
    required this.author,
    required this.lastUpdate,
    this.type = '',
    this.directConnection = false,
    this.repositoryUrl = '',
    this.repositoryLabel = '',
  });

  factory PluginHTTPItem.fromJson(Map<String, dynamic> json) {
    return PluginHTTPItem(
      name: json['name'],
      version: json['version'],
      useNativePlayer: json['useNativePlayer'],
      author: json['author'],
      lastUpdate: json['lastUpdate'] ?? 0,
      type: json['type']?.toString() ?? '',
      directConnection: json['directConnection'] ?? false,
    );
  }

  /// 复制一份并打上来源仓库标记。
  ///
  /// 聚合时使用；原对象不动，避免同一规则被多个仓库共享时串了来源。
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
      type: type,
      directConnection: directConnection,
      repositoryUrl: url,
      repositoryLabel: label,
    );
  }
}
