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

/// 该规则需要的凭据用户还没填过。
class RuleAuthRequiredException implements Exception {
  const RuleAuthRequiredException(this.pluginName);

  final String pluginName;

  @override
  String toString() =>
      'RuleAuthRequiredException: $pluginName requires an account';
}

/// 登录跑过了但没拿到令牌（凭据错了，或接口改了）。
class RuleAuthFailedException implements Exception {
  const RuleAuthFailedException(
    this.pluginName, {
    this.cause,
    this.badCredentials = false,
  });

  final String pluginName;
  final Object? cause;

  /// 为 true 表示登录接口拒绝的是账号本身（HTTP 401/403），
  /// 而不是因为网络错误等其它原因失败。
  final bool badCredentials;

  @override
  String toString() => badCredentials
      ? 'RuleAuthFailedException: $pluginName 账号或密码不正确'
      : 'RuleAuthFailedException: $pluginName login failed'
          '${cause != null ? ' ($cause)' : ''}';
}

/// 由插件规则构建出的不可变运行时快照。
///
/// API 请求可以自带静态请求头。[userAgent] 是规则自己的 User-Agent，
/// 对每一个出站请求（搜索、章节、播放）都生效；为空时退回一个非浏览器的默认值。
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
    this.directConnection = false,
    this.auth,
    this.play,
  });

  /// 规则级直连开关：开启后该规则请求绕过代理直连目标站点。
  final bool directConnection;

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

  /// 可选的 XPath 列表，用于给各章节线路命名，与 [chapterRoads] 按下标对齐。
  /// 留空则沿用自动生成的「播放线路N」标签。
  final String chapterRoadName;
  final ApiSearchConfig searchApiConfig;
  final ApiChapterConfig chapterApiConfig;
  final AntiCrawlerConfig antiCrawlerConfig;

  /// 规则声明的 User-Agent，对搜索、章节与播放请求都生效。
  /// 为空表示「用一个非浏览器的默认值」。
  final String userAgent;

  /// 规则声明的登录流程；规则不需要鉴权时为 null。
  final ApiAuthConfig? auth;

  /// 返回媒体地址的播放接口；必须走 webview 播放时为 null。
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

  /// 是否把存储的插件 cookie 带在请求上。历史上只有搜索与 API 请求会带
  /// cookie，XPath 章节请求不带。
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
