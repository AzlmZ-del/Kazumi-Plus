import 'package:dio/dio.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/api_auth_config.dart';
import 'package:kazumi/plugins/anti_crawler_config.dart';
import 'package:kazumi/plugins/api_rule_config.dart';

typedef RuleCancelToken = CancelToken;

class CaptchaRequiredException implements Exception {
  const CaptchaRequiredException(this.pluginName);

  final String pluginName;

  @override
  String toString() =>
      'CaptchaRequiredException: $pluginName requires captcha verification';
}

class NoResultException implements Exception {
  const NoResultException(this.pluginName);

  final String pluginName;

  @override
  String toString() =>
      'NoResultException: $pluginName returned no search results';
}

class SearchErrorException implements Exception {
  const SearchErrorException(this.pluginName, {this.cause});

  final String pluginName;
  final Object? cause;

  @override
  String toString() =>
      'SearchErrorException: $pluginName search failed${cause != null ? ' ($cause)' : ''}';
}

class ChapterErrorException implements Exception {
  const ChapterErrorException(this.pluginName, {this.cause});

  final String pluginName;
  final Object? cause;

  @override
  String toString() => 'ChapterErrorException: $pluginName chapter query failed'
      '${cause != null ? ' ($cause)' : ''}';
}

/// The rule requires credentials that the user has not entered yet.
class RuleAuthRequiredException implements Exception {
  const RuleAuthRequiredException(this.pluginName);

  final String pluginName;

  @override
  String toString() =>
      'RuleAuthRequiredException: $pluginName requires an account';
}

/// Login ran but did not yield a token (bad credentials or changed API).
class RuleAuthFailedException implements Exception {
  const RuleAuthFailedException(
    this.pluginName, {
    this.cause,
    this.badCredentials = false,
  });

  final String pluginName;
  final Object? cause;

  /// True when the login endpoint rejected the account itself (HTTP 401/403)
  /// rather than failing for another reason such as a network error.
  final bool badCredentials;

  @override
  String toString() => badCredentials
      ? 'RuleAuthFailedException: $pluginName 账号或密码不正确'
      : 'RuleAuthFailedException: $pluginName login failed'
          '${cause != null ? ' ($cause)' : ''}';
}

/// Immutable runtime snapshot built from a plugin rule.
///
/// API requests can provide their own static headers. [userAgent] is the
/// rule's own User-Agent; it applies to every outgoing request (search,
/// chapter and playback), falling back to a non-browser default when empty.
class RuleExecutionConfig {
  const RuleExecutionConfig({
    required this.pluginName,
    required this.baseUrl,
    required this.usePost,
    required this.searchMode,
    required this.chapterMode,
    required this.searchUrl,
    required this.searchList,
    required this.searchName,
    required this.searchResult,
    required this.chapterRoads,
    required this.chapterResult,
    this.chapterRoadName = '',
    required this.searchApiConfig,
    required this.chapterApiConfig,
    required this.antiCrawlerConfig,
    this.userAgent = '',
    this.auth,
    this.play,
  });

  final String pluginName;
  final String baseUrl;
  final bool usePost;
  final String searchMode;
  final String chapterMode;
  final String searchUrl;
  final String searchList;
  final String searchName;
  final String searchResult;
  final String chapterRoads;
  final String chapterResult;

  /// Optional XPath list naming each chapter road, index-aligned with
  /// [chapterRoads]. Empty keeps the generated "播放线路N" labels.
  final String chapterRoadName;
  final ApiSearchConfig searchApiConfig;
  final ApiChapterConfig chapterApiConfig;
  final AntiCrawlerConfig antiCrawlerConfig;

  /// User-Agent declared by the rule. Applies to search, chapter and playback
  /// requests alike. Empty means "use a non-browser default".
  final String userAgent;

  /// Login flow declared by the rule, or null when the rule needs no auth.
  final ApiAuthConfig? auth;

  /// Playback endpoint that returns a media URL, or null when playback has to
  /// go through the webview.
  final ApiPlayConfig? play;
}

class PreparedRuleRequest {
  const PreparedRuleRequest({
    required this.method,
    required this.url,
    this.headers = const <String, dynamic>{},
    this.query = const <String, dynamic>{},
    this.bodyType = ApiBodyType.none,
    this.body,
    this.includeCookies = false,
  });

  final String method;
  final String url;
  final Map<String, dynamic> headers;
  final Map<String, dynamic> query;
  final String bodyType;
  final Object? body;

  /// Whether stored plugin cookies are attached to the request. Historically
  /// only search and API requests send cookies; XPath chapter requests do not.
  final bool includeCookies;
}

class RuleSearchParseResult {
  const RuleSearchParseResult({
    required this.items,
    this.matchedFragments = const <String>[],
    this.diagnostics = const <String>[],
  });

  final List<SearchItem> items;
  final List<String> matchedFragments;
  final List<String> diagnostics;
}

class RuleChapterParseResult {
  const RuleChapterParseResult({
    required this.roads,
    this.diagnostics = const <String>[],
  });

  final List<Road> roads;
  final List<String> diagnostics;
}

class RuleSearchTrace {
  const RuleSearchTrace({
    required this.rawResponse,
    required this.response,
    required this.matchedFragments,
    required this.diagnostics,
  });

  final String rawResponse;
  final PluginSearchResponse response;
  final List<String> matchedFragments;
  final List<String> diagnostics;
}

class RuleChapterTrace {
  const RuleChapterTrace({
    required this.rawResponse,
    required this.roads,
    required this.diagnostics,
  });

  final String rawResponse;
  final List<Road> roads;
  final List<String> diagnostics;
}
