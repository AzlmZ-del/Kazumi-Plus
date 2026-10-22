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

  /// Runs the rule's login flow proactively and caches the fresh token.
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

  /// Visible for tests: drives the production executor directly.
  RuleRequestExecutor get testRequestExecutor => _requestExecutor;

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

  /// Parses HTML harvested from the captcha webview as a search result,
  /// skipping one network round trip after verification. Returns null when
  /// not applicable (API/POST rules) or when the page does not parse into
  /// results (still a challenge page, redirect page, or empty list) — the
  /// caller then falls back to a regular re-search.
  PluginSearchResponse? tryParseHarvestedSearch(
    RuleExecutionConfig config,
    String raw,
  ) {
    if (raw.trim().isEmpty) return null;
    // The webview loads the search URL with GET; API-mode and POST-mode
    // rules may render a different page than the real search response.
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

  /// Runs the login flow on demand (the「点击登录」button) and caches the
  /// token. Reuses [_login], so a failure surfaces as [RuleAuthFailedException]
  /// and a missing account as [RuleAuthRequiredException].
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
      // Touch the store so linters see the dependency; the executor owns the
      // actual credential checks.
      store.hasCredentials(config.pluginName);
    }
  }

  /// Resolves the media URL for [episodeUrl] through the rule's play API.
  ///
  /// Throws [ChapterErrorException] when the rule declares no play endpoint;
  /// callers use that to fall back to the webview.
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

  /// Checks whether a failed XPath search request actually returned an
  /// anti-crawler challenge page.
  ///
  /// Dio rejects non-2xx responses before [XPathRuleStrategy.parseSearch]
  /// gets a chance to inspect the response body. Protected sites commonly
  /// return challenge HTML with HTTP 403/429/503, so reuse the configured
  /// captcha detector against the preserved Dio response body and hand the
  /// request over to the existing captcha flow when it matches.
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

    // Cloudflare marks managed challenge responses with this header.
    // This is useful when the body is empty, compressed unexpectedly, or
    // otherwise unavailable to Dio on a specific platform.
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

  /// Surfaces partially-skipped nodes so incomplete results are traceable
  /// from logs even when the rule succeeds overall.
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

/// Sends a fully prepared request and returns the raw response body.
///
/// Injected so tests can drive the production executor without the network.
typedef RuleTextSender = Future<String> Function(
  PreparedRuleRequest request,
  Map<String, dynamic> headers,
  CancelToken? cancelToken,
);

/// Executes rule requests, adding the login/token handling declared by the
/// rule's `auth` block.
class DefaultRuleRequestExecutor implements RuleRequestExecutor {
  DefaultRuleRequestExecutor({RuleTextSender? textSender})
      : _textSender = textSender ?? _sendViaClient;

  final RuleTextSender _textSender;

  /// Tokens currently being refreshed, so a 401 during the retry itself does
  /// not loop back into another re-login.
  final Set<String> _refreshing = {};

  static Future<String> _sendViaClient(
    PreparedRuleRequest request,
    Map<String, dynamic> headers,
    CancelToken? cancelToken,
  ) {
    return PluginSiteClient.instance.requestText(
      request.url,
      method: request.method,
      headers: headers,
      queryParameters: request.query,
      data: request.method == 'POST' ? request.body : null,
      cancelToken: cancelToken,
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
    // Always log in fresh: the button is an explicit credential check, so a
    // cached token must not mask a password that no longer works.
    await store.clearToken(config.pluginName);
    return _login(config, cancelToken: cancelToken);
  }

  /// Whether [request] was rendered from the rule's own login endpoint —
  /// sending the token to the token issuer makes no sense.
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
        // The cached token was rejected: drop it and log in once more.
        await store.clearToken(config.pluginName);
        final fresh = await _login(config, cancelToken: cancelToken);
        return await _send(request, config,
            token: fresh, cancelToken: cancelToken);
      } finally {
        _refreshing.remove(config.pluginName);
      }
    }
  }

  /// Runs the rule's login request, extracts the token and caches it.
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
      // 401/403 from the login endpoint means the account itself was
      // rejected; anything else (timeout, DNS, 5xx) is a different problem.
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
    // Clearance cookies are bound to the User-Agent they were issued to, so the
    // verified UA must win whenever it exists; sending a different one would
    // make the site serve the challenge page again.
    final ruleUserAgent = config.userAgent.trim();
    final userAgent = verifiedUserAgent ??
        (ruleUserAgent.isEmpty ? null : ruleUserAgent);
    // Header names are lowercased so a rule-supplied 'User-Agent' collides
    // with ours instead of being sent as a second, conflicting header.
    final headers = <String, dynamic>{
      'referer': '${config.baseUrl}/',
      if (cookieHeader.isNotEmpty) 'cookie': cookieHeader,
      for (final entry in request.headers.entries)
        entry.key.toLowerCase(): entry.value,
      'user-agent': ?userAgent,
    };
    // Auth token goes last so it wins over a rule-supplied static header of
    // the same name (lowercased keys collide by design, see above).
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
    return _textSender(request, headers, cancelToken);
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
