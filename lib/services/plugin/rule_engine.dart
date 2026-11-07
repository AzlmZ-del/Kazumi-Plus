import 'package:dio/dio.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/request/clients/plugin_site_client.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/api_rule_strategy.dart';
import 'package:kazumi/services/plugin/plugin_cookie_manager.dart';
import 'package:kazumi/services/plugin/plugin_credentials_store.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/services/plugin/xpath_rule_strategy.dart';

abstract interface class RuleRequestExecutor {
  Future<String> execute(
    PreparedRuleRequest request,
    RuleExecutionConfig config, {
    CancelToken? cancelToken,
  });

  /// 主动跑一遍规则的登录流程，并把新令牌缓存起来。
  Future<String> login(
    RuleExecutionConfig config, {
    CancelToken? cancelToken,
  });
}

class RuleEngine {
  RuleEngine({
    RuleRequestExecutor? requestExecutor,
    ApiRuleStrategy apiStrategy = const ApiRuleStrategy(),
    XPathRuleStrategy xpathStrategy = const XPathRuleStrategy(),
    bool logFailures = true,
  })  : _requestExecutor = requestExecutor ?? DefaultRuleRequestExecutor(),
        _apiStrategy = apiStrategy,
        _xpathStrategy = xpathStrategy,
        _logFailures = logFailures;

  final RuleRequestExecutor _requestExecutor;
  final ApiRuleStrategy _apiStrategy;
  final XPathRuleStrategy _xpathStrategy;
  final bool _logFailures;

  Future<RuleSearchTrace> search(
    RuleExecutionConfig config,
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    late final PreparedRuleRequest request;
    try {
      request = config.searchMode == RuleMode.api
          ? _apiStrategy.prepareRequest(
              config.searchApiConfig.request,
              <String, Object?>{'keyword': keyword},
            )
          : _xpathStrategy.prepareSearchRequest(config, keyword);
    } catch (error, stackTrace) {
      _logFailure(config, 'search request preparation', error, stackTrace);
      throw SearchErrorException(config.pluginName, cause: error);
    }

    late final String raw;
    try {
      raw = await _executeRequest(
        request,
        config,
        phase: 'search request',
        wrapError: (error) =>
            SearchErrorException(config.pluginName, cause: error),
        cancelToken: cancelToken,
      );
    } on SearchErrorException catch (error) {
      if (_isCaptchaChallengeResponse(error, config)) {
        throw CaptchaRequiredException(config.pluginName);
      }
      rethrow;
    }
    try {
      final parsed = config.searchMode == RuleMode.api
          ? _apiStrategy.parseSearch(raw, config.searchApiConfig)
          : _xpathStrategy.parseSearch(raw, config);
      if (parsed.items.isEmpty) {
        throw NoResultException(config.pluginName);
      }
      _logDiagnostics(config, 'search', parsed.diagnostics);
      return RuleSearchTrace(
        rawResponse: raw,
        response: PluginSearchResponse(
          pluginName: config.pluginName,
          data: parsed.items,
        ),
        matchedFragments: parsed.matchedFragments,
        diagnostics: parsed.diagnostics,
      );
    } on CaptchaRequiredException {
      rethrow;
    } on NoResultException {
      rethrow;
    } catch (error, stackTrace) {
      if (_isCancellation(error)) rethrow;
      _logFailure(config, 'search response parsing', error, stackTrace);
      throw SearchErrorException(config.pluginName, cause: error);
    }
  }

  /// 把验证 webview 里抓到的 HTML 直接当作搜索结果解析，
  /// 省掉验证之后的一次网络往返。不适用时（API/POST 规则）返回 null，
  /// 页面解析不出结果时（仍是验证页、跳转页或空列表）也返回 null，
  /// 调用方随后退回常规的重新搜索。
  PluginSearchResponse? tryParseHarvestedSearch(
    RuleExecutionConfig config,
    String raw,
  ) {
    if (raw.trim().isEmpty) return null;
    // webview 是用 GET 加载搜索地址的；API 模式与 POST 模式的规则
    // 渲染出来的页面可能和真正的搜索响应不是一回事。
    if (config.searchMode == RuleMode.api || config.usePost) return null;
    try {
      final parsed = _xpathStrategy.parseSearch(raw, config);
      if (parsed.items.isEmpty) return null;
      _logDiagnostics(config, 'harvested search', parsed.diagnostics);
      return PluginSearchResponse(
        pluginName: config.pluginName,
        data: parsed.items,
      );
    } catch (error) {
      if (_logFailures) {
        KazumiLogger().i(
          'Plugin: ${config.pluginName} harvested page not parseable, '
          'falling back to re-search ($error)',
        );
      }
      return null;
    }
  }

  Future<RuleChapterTrace> queryChapters(
    RuleExecutionConfig config,
    String source, {
    CancelToken? cancelToken,
  }) async {
    late final PreparedRuleRequest request;
    try {
      request = config.chapterMode == RuleMode.api
          ? _apiStrategy.prepareRequest(
              config.chapterApiConfig.request,
              <String, Object?>{'source': source},
            )
          : _xpathStrategy.prepareChapterRequest(config, source);
    } catch (error, stackTrace) {
      _logFailure(config, 'chapter request preparation', error, stackTrace);
      throw ChapterErrorException(config.pluginName, cause: error);
    }

    final raw = await _executeRequest(
      request,
      config,
      phase: 'chapter request',
      wrapError: (error) =>
          ChapterErrorException(config.pluginName, cause: error),
      cancelToken: cancelToken,
    );
    try {
      final parsed = config.chapterMode == RuleMode.api
          ? _apiStrategy.parseChapters(
              raw,
              config.chapterApiConfig,
              source: source,
              baseUrl: config.baseUrl,
            )
          : _xpathStrategy.parseChapters(raw, config);
      if (parsed.roads.isEmpty) {
        throw ChapterErrorException(config.pluginName);
      }
      _logDiagnostics(config, 'chapter', parsed.diagnostics);
      return RuleChapterTrace(
        rawResponse: raw,
        roads: parsed.roads,
        diagnostics: parsed.diagnostics,
      );
    } on ChapterErrorException {
      rethrow;
    } catch (error, stackTrace) {
      if (_isCancellation(error)) rethrow;
      _logFailure(config, 'chapter response parsing', error, stackTrace);
      throw ChapterErrorException(config.pluginName, cause: error);
    }
  }

  /// 按需执行登录流程（对应「点击登录」按钮），并把拿到的令牌缓存下来。
  /// 复用 [_login]，所以失败会抛 [RuleAuthFailedException]，
  /// 缺账号则抛 [RuleAuthRequiredException]。
  Future<String> login(
    RuleExecutionConfig config, {
    CancelToken? cancelToken,
  }) async {
    if (config.auth == null) {
      throw ApiRuleFormatException('该规则未声明登录流程');
    }
    final store = PluginCredentialsStore.instance;
    try {
      return await _requestExecutor.login(config, cancelToken: cancelToken);
    } on RuleAuthRequiredException {
      rethrow;
    } on RuleAuthFailedException {
      rethrow;
    } finally {
      // 碰一下 store 让 lint 看到这个依赖；真正的凭据校验由执行器负责。
      store.hasCredentials(config.pluginName);
    }
  }

  /// 通过规则的播放接口为 [episodeUrl] 解析出媒体地址。
  ///
  /// 规则没有声明播放接口时抛 [ChapterErrorException]，
  /// 调用方据此退回 webview。
  Future<String> resolvePlayUrl(
    RuleExecutionConfig config,
    String episodeUrl, {
    CancelToken? cancelToken,
  }) async {
    final play = config.play;
    if (play == null) {
      throw ChapterErrorException(config.pluginName);
    }
    late final PreparedRuleRequest request;
    try {
      request = _apiStrategy.preparePlayRequest(play, episodeUrl);
    } catch (error, stackTrace) {
      _logFailure(config, 'play request preparation', error, stackTrace);
      throw ChapterErrorException(config.pluginName, cause: error);
    }

    final raw = await _executeRequest(
      request,
      config,
      phase: 'play request',
      wrapError: (error) =>
          ChapterErrorException(config.pluginName, cause: error),
      cancelToken: cancelToken,
    );
    try {
      return _apiStrategy.parsePlayUrl(raw, play);
    } catch (error, stackTrace) {
      if (_isCancellation(error)) rethrow;
      _logFailure(config, 'play response parsing', error, stackTrace);
      throw ChapterErrorException(config.pluginName, cause: error);
    }
  }

  Future<String> _executeRequest(
    PreparedRuleRequest request,
    RuleExecutionConfig config, {    required String phase,
    required Object Function(Object error) wrapError,
    CancelToken? cancelToken,
  }) async {
    try {
      return await _requestExecutor.execute(
        request,
        config,
        cancelToken: cancelToken,
      );
    } catch (error, stackTrace) {
      if (_isCancellation(error)) rethrow;
      _logFailure(config, phase, error, stackTrace);
      throw wrapError(error);
    }
  }

  bool _isCancellation(Object error) {
    return error is NetworkException &&
        error.type == NetworkExceptionType.cancel;
  }

  /// 判断一次失败的 XPath 搜索请求，实际返回的是不是反爬验证页。
  ///
  /// Dio 在 [XPathRuleStrategy.parseSearch] 有机会看响应体之前，
  /// 就已经把非 2xx 响应拒掉了。被防护的站点常用 HTTP 403/429/503
  /// 返回验证页，所以拿配置好的识别器去查 Dio 保留的响应体，
  /// 命中就交给现有的验证流程处理。
  bool _isCaptchaChallengeResponse(
    SearchErrorException error,
    RuleExecutionConfig config,
  ) {
    if (config.searchMode != RuleMode.xpath ||
        !config.antiCrawlerConfig.enabled) {
      return false;
    }

    final cause = error.cause;
    if (cause is! NetworkException ||
        cause.type != NetworkExceptionType.badResponse) {
      return false;
    }

    final rawError = cause.rawError;
    if (rawError is! DioException) return false;

    final response = rawError.response;

    // Cloudflare 用这个响应头标记「托管验证」响应。
    // 当响应体为空、被意外压缩，或某个平台上 Dio 就是拿不到内容时，
    // 这个头就派上用场了。
    final cfMitigated = response?.headers.value('cf-mitigated');
    if (cfMitigated?.toLowerCase() == 'challenge') {
      return true;
    }

    final data = response?.data;
    final raw = data is String ? data : data?.toString() ?? '';
    if (raw.trim().isEmpty) return false;

    try {
      return _xpathStrategy.detectsCaptchaChallenge(
        raw,
        config.antiCrawlerConfig,
      );
    } catch (detectError, stackTrace) {
      _logFailure(
        config,
        'failed response captcha detection',
        detectError,
        stackTrace,
      );
      return false;
    }
  }

  /// 把被部分跳过的节点暴露出来，这样即使规则整体成功，
  /// 也能从日志里追到不完整的结果。
  void _logDiagnostics(
    RuleExecutionConfig config,
    String phase,
    List<String> diagnostics,
  ) {
    if (!_logFailures || diagnostics.isEmpty) return;
    final preview = diagnostics.take(3).join('; ');
    KazumiLogger().w(
      'Plugin: ${config.pluginName} $phase skipped ${diagnostics.length} '
      'node(s): $preview',
    );
  }

  void _logFailure(
    RuleExecutionConfig config,
    String phase,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!_logFailures) return;
    KazumiLogger().w(
      'Plugin: ${config.pluginName} $phase failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// 发送一个完全备好的请求并返回原始响应体。
///
/// 做成可注入，测试就能不联网地驱动生产执行器。
typedef RuleTextSender = Future<String> Function(
  PreparedRuleRequest request,
  Map<String, dynamic> headers,
  CancelToken? cancelToken,
  RuleExecutionConfig config,
);

/// 执行规则请求，并按规则 `auth` 块声明的协议补上登录与令牌处理。
class DefaultRuleRequestExecutor implements RuleRequestExecutor {
  DefaultRuleRequestExecutor({RuleTextSender? textSender})
      : _textSender = textSender ?? _sendViaClient;

  final RuleTextSender _textSender;

  /// 正在刷新中的令牌，避免重试本身又收到 401 时
  /// 回头再触发一次重新登录，形成死循环。
  final Set<String> _refreshing = {};

  static Future<String> _sendViaClient(
    PreparedRuleRequest request,
    Map<String, dynamic> headers,
    CancelToken? cancelToken,
    RuleExecutionConfig config,
  ) {
    return PluginSiteClient.instance.requestText(
      request.url,
      method: request.method,
      headers: headers,
      queryParameters: request.query,
      data: request.method == 'POST' ? request.body : null,
      cancelToken: cancelToken,
      directConnection: config.directConnection,
      // 原生直连通道不走 Dio，body 序列化得自己按 bodyType 来
      // （Dio 会按 content-type 自动把 Map 编成 JSON/form）。
      bodyType: request.bodyType,
    );
  }

  @override
  Future<String> execute(
    PreparedRuleRequest request,
    RuleExecutionConfig config, {
    CancelToken? cancelToken,
  }) async {
    if (config.auth != null && !_isLoginRequest(request, config)) {
      return _executeWithAuth(request, config, cancelToken: cancelToken);
    }
    return _send(request, config, cancelToken: cancelToken);
  }

  @override
  Future<String> login(
    RuleExecutionConfig config, {
    CancelToken? cancelToken,
  }) async {
    if (config.auth == null) {
      throw ApiRuleFormatException('该规则未声明登录流程');
    }
    final store = PluginCredentialsStore.instance;
    if (!store.hasCredentials(config.pluginName)) {
      throw RuleAuthRequiredException(config.pluginName);
    }
    // 每次都重新登录：这个按钮本身就是一次凭据校验，
    // 缓存的令牌不能掩盖一个已经失效的密码。
    await store.clearToken(config.pluginName);
    return _login(config, cancelToken: cancelToken);
  }

  /// 判断 [request] 是不是由规则自己的登录接口构造出来的，
  /// 把令牌发回给签发它的地方没有任何意义。
  bool _isLoginRequest(PreparedRuleRequest request, RuleExecutionConfig config) {
    final loginUrl = config.auth!.login.url.trim();
    return loginUrl.isNotEmpty && request.url.startsWith(loginUrl);
  }

  Future<String> _executeWithAuth(
    PreparedRuleRequest request,
    RuleExecutionConfig config, {
    CancelToken? cancelToken,
  }) async {
    final auth = config.auth!;
    final store = PluginCredentialsStore.instance;
    if (!store.hasCredentials(config.pluginName)) {
      throw RuleAuthRequiredException(config.pluginName);
    }

    var token = store.tokenFor(config.pluginName);
    if (token == null || token.isEmpty) {
      token = await _login(config, cancelToken: cancelToken);
    }

    try {
      return await _send(request, config,
          token: token, cancelToken: cancelToken);
    } on NetworkException catch (error) {
      final status = error.statusCode;
      if (status == null || !auth.shouldRefreshOn(status)) rethrow;
      if (_refreshing.contains(config.pluginName)) rethrow;
      _refreshing.add(config.pluginName);
      try {
        // 缓存的令牌被拒了：丢掉它，再登录一次。
        await store.clearToken(config.pluginName);
        final fresh = await _login(config, cancelToken: cancelToken);
        return await _send(request, config,
            token: fresh, cancelToken: cancelToken);
      } finally {
        _refreshing.remove(config.pluginName);
      }
    }
  }

  /// 跑规则的登录请求，取出令牌并缓存。
  Future<String> _login(
    RuleExecutionConfig config, {
    CancelToken? cancelToken,
  }) async {
    final auth = config.auth!;
    final store = PluginCredentialsStore.instance;
    final username = store.usernameFor(config.pluginName) ?? '';
    final password = store.passwordFor(config.pluginName) ?? '';
    try {
      final request = const ApiRuleStrategy()
          .prepareRequest(auth.login, <String, Object?>{
        'username': username,
        'password': password,
      });
      final raw = await _send(request, config, cancelToken: cancelToken);
      final document = const ApiRuleStrategy().decodeResponse(raw);
      final value = RestrictedJsonPath.readFirst(document, auth.tokenPath);
      final token = value?.toString() ?? '';
      if (token.trim().isEmpty) {
        throw RuleAuthFailedException(config.pluginName);
      }
      await store.saveToken(config.pluginName, token);
      return token;
    } on RuleAuthFailedException {
      rethrow;
    } on ApiRuleFormatException catch (error) {
      throw RuleAuthFailedException(config.pluginName, cause: error);
    } on NetworkException catch (error) {
      // 登录接口返回 401/403 说明账号本身被拒；
      // 其它情况（超时、DNS、5xx）是另一类问题。
      final status = error.statusCode;
      throw RuleAuthFailedException(
        config.pluginName,
        cause: error,
        badCredentials: status == 401 || status == 403,
      );
    }
  }

  Future<String> _send(
    PreparedRuleRequest request,
    RuleExecutionConfig config, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    final cookieHeader = request.includeCookies
        ? await _cookieHeaderFor(config.pluginName, request.url)
        : '';
    final verifiedUserAgent = cookieHeader.isNotEmpty
        ? PluginCookieManager.instance.userAgentFor(config.pluginName)
        : null;
    final auth = config.auth;
    // UA 优先级：clearance cookie 绑定的 UA > 规则自带 UA > 请求层默认值。
    // clearance cookie 与签发它时的 User-Agent 绑定，
    // 所以只要有验证过的 UA 就必须优先用它；
    // 换成别的 UA 会让站点重新返回验证页。
    final ruleUserAgent = config.userAgent.trim();
    final userAgent = verifiedUserAgent ??
        (ruleUserAgent.isEmpty ? null : ruleUserAgent);
    // 头名统一转小写，这样规则里写的 'User-Agent' 会与我们这条撞上，
    // 而不是变成第二个互相冲突的头。
    final headers = <String, dynamic>{
      'referer': '${config.baseUrl}/',
      if (cookieHeader.isNotEmpty) 'cookie': cookieHeader,
      for (final entry in request.headers.entries)
        entry.key.toLowerCase(): entry.value,
      'user-agent': ?userAgent,
    };
    // 认证令牌放在最后，这样它能盖过规则里写死的同名静态头
    // （键统一小写就是为了让它们撞上，见上）。
    final headerName = auth?.headerName.trim() ?? '';
    if (token != null && headerName.isNotEmpty) {
      headers[headerName.toLowerCase()] =
          '${auth!.tokenPrefix}$token';
    }
    if (request.method == 'POST') {
      switch (request.bodyType) {
        case ApiBodyType.json:
          headers.putIfAbsent('content-type', () => 'application/json');
          break;
        case ApiBodyType.form:
          headers.putIfAbsent(
            'content-type',
            () => 'application/x-www-form-urlencoded',
          );
          break;
      }
    }
    return _textSender(request, headers, cancelToken, config);
  }

  Future<String> _cookieHeaderFor(String pluginName, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    try {
      final cookies =
          await PluginCookieManager.instance.loadForRequest(pluginName, uri);
      return cookies
          .map((cookie) => '${cookie.name}=${cookie.value}')
          .join('; ');
    } catch (_) {
      return '';
    }
  }
}
