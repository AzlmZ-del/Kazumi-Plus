import 'package:kazumi/plugins/api_rule_config.dart';

/// Per-rule login flow definition.
///
/// Credentials themselves never live here (or anywhere in the rule JSON):
/// they are entered by the user and stored locally. This config only
/// describes *how* to exchange credentials for a token and where to put it.
class ApiAuthConfig {
  ApiAuthConfig({
    ApiRequestConfig? login,
    this.tokenPath = defaultTokenPath,
    this.headerName = defaultHeaderName,
    this.tokenPrefix = '',
    List<int>? refreshOnStatus,
  })  : login = login ?? ApiRequestConfig(),
        refreshOnStatus = refreshOnStatus ?? const [401];

  static const String defaultTokenPath = r'$.data.token';
  static const String defaultHeaderName = 'Authorization';

  /// Login request template. `@username` / `@password` are rendered from the
  /// locally stored credentials via the regular template mechanism.
  final ApiRequestConfig login;

  /// JSONPath over the login response that yields the token string.
  final String tokenPath;

  /// Request header the token is sent in.
  final String headerName;

  /// Prepended to the token when building the header value. Empty by
  /// default: some sites return tokens that already carry "Bearer ".
  final String tokenPrefix;

  /// Response status codes that invalidate the cached token and trigger one
  /// re-login + retry.
  final List<int> refreshOnStatus;

  bool shouldRefreshOn(int statusCode) => refreshOnStatus.contains(statusCode);

  factory ApiAuthConfig.fromJson(Map<String, dynamic> json) {
    final login = json['login'];
    ApiRequestConfig loginConfig = login is Map
        ? ApiRequestConfig.fromJson(_asStringMap(login))
        : ApiRequestConfig();
    if (loginConfig.method == 'GET' &&
        loginConfig.bodyType == ApiBodyType.none &&
        loginConfig.body == null) {
      // Login endpoints are POST in practice; ApiRequestConfig itself
      // defaults to GET because it also serves search/chapter requests.
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
    );
  }

  Map<String, dynamic> toJson() => {
        'login': login.toJson(),
        'tokenPath': tokenPath,
        if (headerName != defaultHeaderName) 'headerName': headerName,
        if (tokenPrefix.isNotEmpty) 'tokenPrefix': tokenPrefix,
        'refreshOnStatus': refreshOnStatus,
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
