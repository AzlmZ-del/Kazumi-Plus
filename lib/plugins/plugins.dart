import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/anti_crawler_config.dart';
import 'package:kazumi/plugins/api_auth_config.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/plugin/api_rule_engine.dart';
import 'package:kazumi/utils/episode_url.dart';
import 'package:kazumi/utils/http_headers.dart';

export 'package:kazumi/plugins/api_auth_config.dart'
    show ApiAuthConfig;
export 'package:kazumi/services/plugin/rule_engine_models.dart'
    show
        CaptchaRequiredException,
        NoResultException,
        SearchErrorException,
        ChapterErrorException,
        RuleAuthRequiredException,
        RuleAuthFailedException;

String pluginNameKey(String name) => name.toLowerCase();

class Plugin {
  static final RuleEngine _ruleEngine = RuleEngine();

  String api;
  String type;
  String name;
  String version;
  bool muliSources;

  /// 旧版 schema 字段，为兼容规则的导入导出而保留。
  bool useWebview;

  /// 旧版 schema 字段，为兼容规则的导入导出而保留。
  bool useNativePlayer;
  bool usePost;
  bool useLegacyParser;
  bool adBlocker;

  /// 开启后该规则的所有请求（搜索/详情/选集/播放 API）不走代理直连。
  bool directConnection;

  /// 用户在编辑器里动过直连开关。动过 → 更新源时本地赢；
  /// 没动过 → 跟随源内 directConnection 参数。持久化。
  bool directConnectionUserOverridden;

  /// 源 JSON 未写 directConnection 键时为 true（缺省态）。
  /// 非 fromJson 构造（编辑器新建等）恒为 false，序列化时不写出。
  bool directConnectionUnspecified;
  String userAgent;
  String baseUrl;
  String searchURL;
  String searchList;
  String searchName;
  String searchResult;
  String chapterRoads;
  String chapterResult;
  String referer;

  /// 可选的 XPath 列表，其文本作为各章节线路的名字，与 [chapterRoads]
  /// 按下标一一对应。为空时线路退回自动生成的名称，
  /// "播放线路N" labels.
  String chapterRoadName;
  String searchMode;
  String chapterMode;
  ApiSearchConfig searchApiConfig;
  ApiChapterConfig chapterApiConfig;
  AntiCrawlerConfig antiCrawlerConfig;

  /// 可选的单规则登录流程。不需要鉴权的规则为 null；
  /// 凭据本身存在本地。
  ApiAuthConfig? auth;

  /// 规则源类型标签：API / XPath / 混合，由搜索结果与章节的解析模式推导。
  ///
  /// 不看 [api]：那是「所需最低客户端级别」，保存时会被写成 apiLevel（9），
  /// 当类型用会落进默认分支变空串。
  String get sourceTypeLabel {
    final searchIsApi = searchMode == RuleMode.api;
    final chapterIsApi = chapterMode == RuleMode.api;
    if (searchIsApi && chapterIsApi) return 'API';
    if (!searchIsApi && !chapterIsApi) return 'XPath';
    return '混合';
  }

  Plugin({
    required this.api,
    required this.type,
    required this.name,
    required this.version,
    required this.muliSources,
    required this.useWebview,
    required this.useNativePlayer,
    required this.usePost,
    required this.useLegacyParser,
    required this.adBlocker,
    required this.directConnection,
    this.directConnectionUserOverridden = false,
    this.directConnectionUnspecified = false,
    required this.userAgent,
    required this.baseUrl,
    required this.searchURL,
    required this.searchList,
    required this.searchName,
    required this.searchResult,
    required this.chapterRoads,
    required this.chapterResult,
    required this.referer,
    this.chapterRoadName = '',
    this.searchMode = RuleMode.xpath,
    this.chapterMode = RuleMode.xpath,
    ApiSearchConfig? searchApiConfig,
    ApiChapterConfig? chapterApiConfig,
    AntiCrawlerConfig? antiCrawlerConfig,
    this.auth,
  })  : searchApiConfig = searchApiConfig ?? ApiSearchConfig(),
        chapterApiConfig = chapterApiConfig ?? ApiChapterConfig(),
        antiCrawlerConfig = antiCrawlerConfig ?? AntiCrawlerConfig.empty();

  factory Plugin.fromJson(Map<String, dynamic> json) {
    return Plugin(
      api: json['api']?.toString() ?? '1',
      type: json['type'] as String? ?? 'anime',
      name: json['name'] as String? ?? '',
      version: json['version']?.toString() ?? '',
      muliSources: json['muliSources'] as bool? ?? true,
      useWebview: json['useWebview'] as bool? ?? true,
      useNativePlayer: json['useNativePlayer'] as bool? ?? true,
      usePost: json['usePost'] ?? false,
      useLegacyParser: json['useLegacyParser'] ?? false,
      directConnection: json['directConnection'] ?? false,
      directConnectionUserOverridden:
          json['directConnectionUserOverridden'] ?? false,
      directConnectionUnspecified: !json.containsKey('directConnection'),
      adBlocker: json['adBlocker'] ?? false,
      userAgent: json['userAgent'] as String? ?? '',
      baseUrl: json['baseURL'] as String? ?? '',
      searchURL: json['searchURL'] as String? ?? '',
      searchList: json['searchList'] as String? ?? '',
      searchName: json['searchName'] as String? ?? '',
      searchResult: json['searchResult'] as String? ?? '',
      chapterRoads: json['chapterRoads'] as String? ?? '',
      chapterResult: json['chapterResult'] as String? ?? '',
      chapterRoadName: json['chapterRoadName'] as String? ?? '',
      referer: json['referer'] ?? '',
      searchMode: RuleMode.normalize(json['searchMode']),
      chapterMode: RuleMode.normalize(json['chapterMode']),
      searchApiConfig: json['searchApiConfig'] is Map
          ? ApiSearchConfig.fromJson(
              Map<String, dynamic>.from(json['searchApiConfig']),
            )
          : ApiSearchConfig(),
      chapterApiConfig: json['chapterApiConfig'] is Map
          ? ApiChapterConfig.fromJson(
              Map<String, dynamic>.from(json['chapterApiConfig']),
            )
          : ApiChapterConfig(),
      antiCrawlerConfig: json['antiCrawlerConfig'] != null
          ? AntiCrawlerConfig.fromJson(
              Map<String, dynamic>.from(json['antiCrawlerConfig']),
            )
          : AntiCrawlerConfig.empty(),
      auth: json['auth'] is Map
          ? ApiAuthConfig.fromJson(
              Map<String, dynamic>.from(json['auth']),
            )
          : null,
    );
  }

  factory Plugin.fromTemplate() {
    return Plugin(
      api: ApiEndpoints.apiLevel.toString(),
      type: 'anime',
      name: '',
      version: '',
      muliSources: true,
      useWebview: true,
      useNativePlayer: true,
      usePost: false,
      useLegacyParser: false,
      directConnection: false,
      adBlocker: false,
      userAgent: '',
      baseUrl: '',
      searchURL: '',
      searchList: '',
      searchName: '',
      searchResult: '',
      chapterRoads: '',
      chapterResult: '',
      chapterRoadName: '',
      referer: '',
      searchMode: RuleMode.xpath,
      chapterMode: RuleMode.xpath,
      searchApiConfig: ApiSearchConfig(),
      chapterApiConfig: ApiChapterConfig(),
      antiCrawlerConfig: AntiCrawlerConfig.empty(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'api': api,
      'type': type,
      'name': name,
      'version': version,
      'muliSources': muliSources,
      'useWebview': useWebview,
      'useNativePlayer': useNativePlayer,
      'usePost': usePost,
      'useLegacyParser': useLegacyParser,
      'directConnection': directConnection,
      'directConnectionUserOverridden': directConnectionUserOverridden,
      'adBlocker': adBlocker,
      'userAgent': userAgent,
      'baseURL': baseUrl,
      'searchURL': searchURL,
      'searchList': searchList,
      'searchName': searchName,
      'searchResult': searchResult,
      'chapterRoads': chapterRoads,
      'chapterResult': chapterResult,
      if (chapterRoadName.isNotEmpty) 'chapterRoadName': chapterRoadName,
      'referer': referer,
      'searchMode': searchMode,
      'chapterMode': chapterMode,
      // 落盘会重新序列化整个插件列表，所以即使当前模式指向 XPath，
      // 已配置好的 API 规则也要原样保住。
      if (searchMode == RuleMode.api || searchApiConfig.request.url.isNotEmpty)
        'searchApiConfig': searchApiConfig.toJson(),
      if (chapterMode == RuleMode.api ||
          chapterApiConfig.request.url.isNotEmpty)
        'chapterApiConfig': chapterApiConfig.toJson(),
      'antiCrawlerConfig': antiCrawlerConfig.toJson(),
      if (auth != null) 'auth': auth!.toJson(),
    };
  }

  bool get usesApiSearch => searchMode == RuleMode.api;

  bool get requiresNewerClient => int.parse(api) > ApiEndpoints.apiLevel;

  RuleExecutionConfig get _executionConfig => RuleExecutionConfig(
        pluginName: name,
        baseUrl: baseUrl,
        usePost: usePost,
        searchMode: searchMode,
        chapterMode: chapterMode,
        searchUrl: searchURL,
        searchList: searchList,
        searchName: searchName,
        searchResult: searchResult,
        chapterRoads: chapterRoads,
        chapterResult: chapterResult,
        chapterRoadName: chapterRoadName,
        searchApiConfig: searchApiConfig,
        chapterApiConfig: chapterApiConfig,
        antiCrawlerConfig: antiCrawlerConfig,
        // 规则自带的 UA 对搜索/章节/播放一律生效，空则由请求层用非浏览器 UA 兜底。
        userAgent: userAgent,
        directConnection: directConnection,
        // 停用的登录流程对运行时完全不可见，但配置本身留在规则里。
        auth: authEnabled ? auth : null,
        play: chapterApiConfig.play,
      );

  /// 播放能否跳过 webview，直接调用规则的播放接口。
  bool get hasPlayApi => chapterApiConfig.play != null;

  /// 通过规则的播放接口为 [episodeUrl] 解析媒体地址。
  ///
  /// 请求失败或规则未声明播放接口时抛 [ChapterErrorException]。
  Future<String> resolvePlayUrl(
    String episodeUrl, {
    RuleCancelToken? cancelToken,
  }) {
    return _ruleEngine.resolvePlayUrl(
      _executionConfig,
      episodeUrl,
      cancelToken: cancelToken,
    );
  }

  /// 规则的登录流程是否真正启用；规则可以在开关关闭时
  /// 仍保留登录模板。
  bool get authEnabled => auth?.enabled ?? false;

  /// 立刻跑一遍规则的登录流程并缓存新令牌。
  ///
  /// 规则未声明登录流程时抛 [ApiRuleFormatException]；
  /// 没存账号时抛 [RuleAuthRequiredException]；
  /// 登录接口拒绝请求时抛 [RuleAuthFailedException]。
  Future<String> login({RuleCancelToken? cancelToken}) {
    return _ruleEngine.login(_executionConfig, cancelToken: cancelToken);
  }

  Future<RuleSearchTrace> traceSearch(
    String keyword, {
    RuleCancelToken? cancelToken,
  }) {
    return _ruleEngine.search(
      _executionConfig,
      keyword,
      cancelToken: cancelToken,
    );
  }

  Future<RuleChapterTrace> traceChapters(
    String source, {
    RuleCancelToken? cancelToken,
  }) {
    return _ruleEngine.queryChapters(
      _executionConfig,
      source,
      cancelToken: cancelToken,
    );
  }

  /// 把验证 webview 里抓到的 HTML 当作搜索结果解析；
  /// 不适用时返回 null，让调用方退回 [queryBangumi]。
  PluginSearchResponse? parseHarvestedSearch(String html) {
    return _ruleEngine.tryParseHarvestedSearch(_executionConfig, html);
  }

  Future<PluginSearchResponse> queryBangumi(
    String keyword, {
    bool shouldRethrow = false,
    RuleCancelToken? cancelToken,
  }) async {
    try {
      return (await traceSearch(keyword, cancelToken: cancelToken)).response;
    } on CaptchaRequiredException {
      rethrow;
    } on NoResultException {
      rethrow;
    } on SearchErrorException {
      if (shouldRethrow) rethrow;
      return PluginSearchResponse(pluginName: name, data: <SearchItem>[]);
    }
  }

  Future<List<Road>> queryChapterRoads(
    String source, {
    RuleCancelToken? cancelToken,
  }) async {
    return (await traceChapters(source, cancelToken: cancelToken)).roads;
  }

  String buildFullUrl(String urlItem) {
    return normalizeEpisodeUrl(baseUrl, urlItem);
  }

  /// 解析或下载最终媒体资源时使用的请求头。
  ///
  /// 播放/下载层保持浏览器 UA：媒体 CDN 一般不做 TLS 指纹校验，反而常见按
  /// 浏览器 UA 做防盗链，换成非浏览器 UA 有被拒的风险。WAF 指纹问题只出现在
  /// 规则抓取 HTML/API 那一层（见 plugin_site_client）。
  Map<String, String> buildHttpHeaders() {
    return {
      'user-agent': userAgent.isEmpty ? getRandomUA() : userAgent,
      if (referer.isNotEmpty) 'referer': referer,
    };
  }
}
