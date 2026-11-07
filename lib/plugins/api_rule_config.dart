class RuleMode {
  static const String xpath = 'xpath';
  static const String api = 'api';

  static String normalize(Object? value) {
    return value == api ? api : xpath;
  }
}

class ApiBodyType {
  static const String none = 'none';
  static const String json = 'json';
  static const String form = 'form';

  static String normalize(Object? value) {
    return switch (value) {
      json => json,
      form => form,
      _ => none,
    };
  }
}

class ApiChapterFormat {
  static const String nested = 'nested';
  static const String delimited = 'delimited';

  static String normalize(Object? value) {
    return value == delimited ? delimited : nested;
  }
}

class ApiRequestConfig {
  String method;
  String url;
  Map<String, dynamic> headers;
  Map<String, dynamic> query;
  String bodyType;
  dynamic body;

  ApiRequestConfig({
    this.method = 'GET',
    this.url = '',
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
    this.bodyType = ApiBodyType.none,
    this.body,
  })  : headers = headers ?? <String, dynamic>{},
        query = query ?? <String, dynamic>{};

  factory ApiRequestConfig.fromJson(Map<String, dynamic> json) {
    return ApiRequestConfig(
      method: (json['method'] as String? ?? 'GET').toUpperCase(),
      url: json['url'] as String? ?? '',
      headers: _asStringMap(json['headers']),
      query: _asStringMap(json['query']),
      bodyType: ApiBodyType.normalize(json['bodyType']),
      body: json['body'],
    );
  }

  Map<String, dynamic> toJson() => {
        'method': method.toUpperCase(),
        'url': url,
        if (headers.isNotEmpty) 'headers': headers,
        if (query.isNotEmpty) 'query': query,
        if (bodyType != ApiBodyType.none) 'bodyType': bodyType,
        if (bodyType != ApiBodyType.none && body != null) 'body': body,
      };
}

class ApiSearchConfig {
  ApiRequestConfig request;
  String listPath;
  String namePath;
  String sourcePath;

  /// 把 `@source` 替换掉后得到的详情页 URL；留空则保留原值。
  final String sourceTemplate;

  ApiSearchConfig({
    ApiRequestConfig? request,
    this.listPath = r'$.data[*]',
    this.namePath = r'$.name',
    this.sourcePath = r'$.url',
    String sourceTemplate = '',
  })  : request = request ?? ApiRequestConfig(),
        sourceTemplate = sourceTemplate.trim();

  factory ApiSearchConfig.fromJson(Map<String, dynamic> json) {
    return ApiSearchConfig(
      request: ApiRequestConfig.fromJson(_asStringMap(json['request'])),
      listPath: json['listPath'] as String? ?? r'$.data[*]',
      namePath: json['namePath'] as String? ?? r'$.name',
      sourcePath: json['sourcePath'] as String? ?? r'$.url',
      sourceTemplate: json['sourceTemplate'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'request': request.toJson(),
        'listPath': listPath,
        'namePath': namePath,
        'sourcePath': sourcePath,
        if (sourceTemplate.isNotEmpty) 'sourceTemplate': sourceTemplate,
      };
}

class ApiEpisodePageConfig {
  /// 最终播放页 URL 的模板。
  String url;

  /// 查询参数，可用响应与集索引变量渲染。
  Map<String, dynamic> query;

  ApiEpisodePageConfig({
    this.url = '',
    Map<String, dynamic>? query,
  }) : query = query ?? <String, dynamic>{};

  factory ApiEpisodePageConfig.fromJson(Map<String, dynamic> json) {
    return ApiEpisodePageConfig(
      url: json['url'] as String? ?? '',
      query: _asStringMap(json['query']),
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'query': query,
      };
}

/// 通过调用接口把剧集页 URL 换成媒体 URL。
///
/// 提供播放页的规则是在 webview 里解析的。而那些通过带鉴权接口
/// 下发签名媒体地址的站点没法这样处理，因为 webview 没有凭据。
/// 这类规则改为声明本块：把剧集 URL 当接口调用请求一次，
/// 再从 JSON 响应里读出媒体地址。
class ApiPlayConfig {
  /// 用来取媒体地址的请求。若 [ApiRequestConfig.url] 为空，
  /// 就以剧集页 URL 本身当接口地址。
  ApiRequestConfig request;

  /// 媒体地址在响应里的 JSONPath。
  String urlPath;

  ApiPlayConfig({
    ApiRequestConfig? request,
    this.urlPath = r'$.data.url',
  }) : request = request ?? ApiRequestConfig();

  factory ApiPlayConfig.fromJson(Map<String, dynamic> json) {
    return ApiPlayConfig(
      request: ApiRequestConfig.fromJson(_asStringMap(json['request'])),
      urlPath: json['urlPath'] as String? ?? r'$.data.url',
    );
  }

  Map<String, dynamic> toJson() => {
        'request': request.toJson(),
        'urlPath': urlPath,
      };
}

class ApiChapterConfig {
  ApiRequestConfig request;
  String format;

  // 嵌套 JSON 响应的字段映射。
  String roadsPath;
  String roadNamePath;
  String episodesPath;
  String episodeNamePath;

  /// 指向播放入口 URL（播放页或直链媒体）的 JSONPath。
  /// 若由 [episodePage] 自行拼出最终播放页 URL，这里可以留空。
  String episodeUrlPath;

  // 分隔符字符串响应的字段映射。
  String roadNamesPath;
  String roadEpisodesPath;
  String roadSeparator;
  String episodeSeparator;
  String fieldSeparator;

  /// 对章节响应做的具名 JSONPath 捕获，作为模板变量暴露给 [episodePage]。
  Map<String, String> variables;

  /// 可选的最终播放页模板，用它替代响应里给出的 URL。
  ApiEpisodePageConfig? episodePage;

  /// 可选：把剧集 URL 换成媒体 URL 的接口调用。设置之后，
  /// 播放会跳过 webview，直接请求该接口。
  ApiPlayConfig? play;

  ApiChapterConfig({
    ApiRequestConfig? request,
    this.format = ApiChapterFormat.nested,
    this.roadsPath = r'$.data.roads[*]',
    this.roadNamePath = r'$.name',
    this.episodesPath = r'$.episodes[*]',
    this.episodeNamePath = r'$.name',
    this.episodeUrlPath = r'$.url',
    this.roadNamesPath = '',
    this.roadEpisodesPath = '',
    this.roadSeparator = r'$$$',
    this.episodeSeparator = '#',
    this.fieldSeparator = r'$',
    Map<String, String>? variables,
    this.episodePage,
    this.play,
  })  : request = request ?? ApiRequestConfig(),
        variables = variables ?? <String, String>{};

  factory ApiChapterConfig.fromJson(Map<String, dynamic> json) {
    final rawVariables = _asStringMap(json['variables']);
    return ApiChapterConfig(
      request: ApiRequestConfig.fromJson(_asStringMap(json['request'])),
      format: ApiChapterFormat.normalize(json['format']),
      roadsPath: json['roadsPath'] as String? ?? r'$.data.roads[*]',
      roadNamePath: json['roadNamePath'] as String? ?? r'$.name',
      episodesPath: json['episodesPath'] as String? ?? r'$.episodes[*]',
      episodeNamePath: json['episodeNamePath'] as String? ?? r'$.name',
      episodeUrlPath: json['episodeUrlPath'] as String? ?? r'$.url',
      roadNamesPath: json['roadNamesPath'] as String? ?? '',
      roadEpisodesPath: json['roadEpisodesPath'] as String? ?? '',
      roadSeparator: json['roadSeparator'] as String? ?? r'$$$',
      episodeSeparator: json['episodeSeparator'] as String? ?? '#',
      fieldSeparator: json['fieldSeparator'] as String? ?? r'$',
      variables: rawVariables.map(
        (key, value) => MapEntry(key, value.toString()),
      ),
      episodePage: json['episodePage'] is Map
          ? ApiEpisodePageConfig.fromJson(_asStringMap(json['episodePage']))
          : null,
      play: json['play'] is Map
          ? ApiPlayConfig.fromJson(_asStringMap(json['play']))
          : null,
    );
  }

  /// 是否有任何嵌套格式的字段偏离了默认值。落盘时会重新序列化每个插件，
  /// 所以即使 [format] 指向另一种格式，被改过的非活动那一侧也必须保住。
  bool get _hasNestedConfig =>
      roadsPath != r'$.data.roads[*]' ||
      roadNamePath != r'$.name' ||
      episodesPath != r'$.episodes[*]' ||
      episodeNamePath != r'$.name' ||
      episodeUrlPath != r'$.url';

  bool get _hasDelimitedConfig =>
      roadNamesPath.isNotEmpty || roadEpisodesPath.isNotEmpty;

  /// 序列化当前 [format] 的字段；若另一种格式带有非默认配置，
  /// 连同它的字段一起序列化。
  Map<String, dynamic> toJson() => {
        'request': request.toJson(),
        'format': format,
        if (format == ApiChapterFormat.nested || _hasNestedConfig) ...{
          'roadsPath': roadsPath,
          'roadNamePath': roadNamePath,
          'episodesPath': episodesPath,
          'episodeNamePath': episodeNamePath,
          'episodeUrlPath': episodeUrlPath,
        },
        if (format == ApiChapterFormat.delimited || _hasDelimitedConfig) ...{
          'roadNamesPath': roadNamesPath,
          'roadEpisodesPath': roadEpisodesPath,
          'roadSeparator': roadSeparator,
          'episodeSeparator': episodeSeparator,
          'fieldSeparator': fieldSeparator,
        },
        if (variables.isNotEmpty) 'variables': variables,
        if (episodePage != null) 'episodePage': episodePage!.toJson(),
        if (play != null) 'play': play!.toJson(),
      };
}

Map<String, dynamic> _asStringMap(Object? value) {
  if (value is! Map) return <String, dynamic>{};
  return value.map((key, value) => MapEntry(key.toString(), value));
}
