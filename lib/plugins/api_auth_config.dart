import 'package:kazumi/plugins/api_rule_config.dart';

/// 单规则的登录流程定义。
///
/// 凭据本身永远不在这里（也不在规则 JSON 的任何位置）：它们由用户输入、
/// 存在本地。这份配置只描述**如何**用凭据换到令牌，以及令牌该放在哪。
class ApiAuthConfig {
  ApiAuthConfig({
    ApiRequestConfig? login,
    this.tokenPath = defaultTokenPath,
    this.headerName = defaultHeaderName,
    this.tokenPrefix = '',
    List<int>? refreshOnStatus,
    this.enabled = true,
  })  : login = login ?? ApiRequestConfig(),
        refreshOnStatus = refreshOnStatus ?? const [401];

  static const String defaultTokenPath = r'$.data.token';
  static const String defaultHeaderName = 'Authorization';

  /// 运行时是否启用这条登录流程。
  ///
  /// 在编辑器里关掉登录只会改这个标志，配置原样保留：
  /// 请求模板仍留在规则 JSON 里，重新打开即恢复原样。
  final bool enabled;

  /// 登录请求模板。`@username` / `@password` 会通过常规模板机制
  /// 从本地凭据渲染出来。
  final ApiRequestConfig login;

  /// 在登录响应上取令牌字符串的 JSONPath。
  final String tokenPath;

  /// 令牌放在哪个请求头里发送。
  final String headerName;

  /// 拼装请求头值时加在令牌前面的前缀。默认为空：
  /// 有些站点返回的令牌本身就带 "Bearer "。
  final String tokenPrefix;

  /// 会判定缓存令牌失效的响应状态码，命中后重新登录并重试一次。
  final List<int> refreshOnStatus;

  bool shouldRefreshOn(int statusCode) => refreshOnStatus.contains(statusCode);

  /// 同一套流程，但翻转启用标志。用户关掉登录又想保留模板时，
  /// 编辑器用它来构造新配置。
  ApiAuthConfig copyWith({bool? enabled}) => ApiAuthConfig(
        login: login,
        tokenPath: tokenPath,
        headerName: headerName,
        tokenPrefix: tokenPrefix,
        refreshOnStatus: refreshOnStatus,
        enabled: enabled ?? this.enabled,
      );

  factory ApiAuthConfig.fromJson(Map<String, dynamic> json) {
    final login = json['login'];
    ApiRequestConfig loginConfig = login is Map
        ? ApiRequestConfig.fromJson(_asStringMap(login))
        : ApiRequestConfig();
    if (loginConfig.method == 'GET' &&
        loginConfig.bodyType == ApiBodyType.none &&
        loginConfig.body == null) {
      // 登录接口实际都是 POST；ApiRequestConfig 自身默认 GET，
      // 因为它同时要服务搜索与章节请求。
      loginConfig = ApiRequestConfig(
        method: 'POST',
        url: loginConfig.url,
        headers: loginConfig.headers,
        query: loginConfig.query,
        bodyType: ApiBodyType.json,
        body: loginConfig.body,
      );
    }
    return ApiAuthConfig(
      login: loginConfig,
      tokenPath: json['tokenPath'] as String? ?? defaultTokenPath,
      headerName: json['headerName'] as String? ?? defaultHeaderName,
      tokenPrefix: json['tokenPrefix'] as String? ?? '',
      refreshOnStatus: _statusCodes(json['refreshOnStatus']),
      // 老规则没有这个字段，默认当启用。
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'login': login.toJson(),
        'tokenPath': tokenPath,
        if (headerName != defaultHeaderName) 'headerName': headerName,
        if (tokenPrefix.isNotEmpty) 'tokenPrefix': tokenPrefix,
        'refreshOnStatus': refreshOnStatus,
        if (!enabled) 'enabled': false,
      };

  static List<int> _statusCodes(Object? value) {
    if (value is! List) return const [401];
    final codes = value
        .map((entry) => entry is num ? entry.toInt() : int.tryParse('$entry'))
        .whereType<int>()
        .where((code) => code >= 100 && code <= 599)
        .toList();
    return codes.isEmpty ? const [401] : codes;
  }

  static Map<String, dynamic> _asStringMap(Object? value) {
    if (value is! Map) return <String, dynamic>{};
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
}
