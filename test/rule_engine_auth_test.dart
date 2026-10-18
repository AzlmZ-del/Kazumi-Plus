import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/plugins/api_auth_config.dart';
import 'package:kazumi/plugins/anti_crawler_config.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/plugin/plugin_credentials_store.dart';
import 'package:kazumi/services/plugin/rule_engine.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.basePath);

  final String basePath;

  @override
  Future<String?> getApplicationSupportPath() async => basePath;
  @override
  Future<String?> getTemporaryPath() async => basePath;
}

/// Records every request the production executor sends and answers from a
/// scripted queue, so the login chain is exercised for real.
class _ScriptedSender {
  _ScriptedSender(this.responses);

  final List<Object> responses;
  final List<({PreparedRuleRequest request, Map<String, dynamic> headers})>
      sent = [];

  Future<String> call(
    PreparedRuleRequest request,
    Map<String, dynamic> headers,
    dynamic cancelToken,
  ) async {
    sent.add((request: request, headers: headers));
    final response = responses.removeAt(0);
    if (response is Exception) throw response;
    return response as String;
  }

  int get loginCalls => sent
      .where((entry) => entry.request.url.endsWith('/api/auth/login'))
      .length;
}

RuleExecutionConfig _config({ApiAuthConfig? auth}) {
  return RuleExecutionConfig(
    pluginName: 'test-rule',
    baseUrl: 'https://example.org',
    usePost: false,
    searchMode: RuleMode.api,
    chapterMode: RuleMode.api,
    searchUrl: '',
    searchList: r'$.data[*]',
    searchName: r'$.name',
    searchResult: r'$.url',
    chapterRoads: '',
    chapterResult: '',
    searchApiConfig: ApiSearchConfig(request: ApiRequestConfig()),
    chapterApiConfig: ApiChapterConfig(),
    antiCrawlerConfig: AntiCrawlerConfig.empty(),
    auth: auth,
  );
}

PreparedRuleRequest _request(String url) {
  return PreparedRuleRequest(method: 'GET', url: url);
}

Future<void> _saveCredentials({
  String username = 'user',
  String password = 'pass',
}) {
  return PluginCredentialsStore.instance.saveCredentials(
    'test-rule',
    username: username,
    password: password,
  );
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('rule_engine_auth_test');
    PathProviderPlatform.instance = _TestPaths(tempDir.path);
    Hive.init(tempDir.path);
  });

  setUp(() async {
    await Hive.deleteBoxFromDisk('pluginCredentials');
    PluginCredentialsStore.instance = PluginCredentialsStore.fresh();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  final login = ApiAuthConfig(
    login: ApiRequestConfig(
      method: 'POST',
      url: 'https://example.org/api/auth/login',
      bodyType: ApiBodyType.json,
      body: '{"username":"@username","password":"@password"}',
    ),
  );

  test('a rule without auth never touches the credentials store', () async {
    final sender = _ScriptedSender(['{"ok":true}']);
    final executor = DefaultRuleRequestExecutor(textSender: sender.call);
    final output =
        await executor.execute(_request('https://example.org/api/x'), _config());
    expect(output, '{"ok":true}');
    expect(sender.sent.single.request.url, 'https://example.org/api/x');
    expect(sender.sent.single.headers.containsKey('authorization'), isFalse);
  });

  test('missing credentials fail before any request is sent', () async {
    final sender = _ScriptedSender(['{}']);
    final executor = DefaultRuleRequestExecutor(textSender: sender.call);
    await expectLater(
      executor.execute(
          _request('https://example.org/api/x'), _config(auth: login)),
      throwsA(isA<RuleAuthRequiredException>()),
    );
    expect(sender.sent, isEmpty);
  });

  test('the first request logs in and carries the token', () async {
    await _saveCredentials();
    final sender = _ScriptedSender([
      '{"data":{"token":"tok-1"}}',
      '{"data":[{"name":"a"}]}',
    ]);
    final executor = DefaultRuleRequestExecutor(textSender: sender.call);
    final output = await executor.execute(
        _request('https://example.org/api/search'), _config(auth: login));

    expect(output, '{"data":[{"name":"a"}]}');
    expect(sender.loginCalls, 1);
    final loginSent = sender.sent.first;
    expect(loginSent.request.method, 'POST');
    expect(loginSent.request.body, '{"username":"user","password":"pass"}');
    expect(loginSent.headers['content-type'], 'application/json');
    // The login request must not carry the token it is about to obtain.
    expect(loginSent.headers.containsKey('authorization'), isFalse);
    expect(sender.sent.last.headers['authorization'], 'tok-1');
    expect(PluginCredentialsStore.instance.tokenFor('test-rule'), 'tok-1');
  });

  test('a rejected token logs in again and retries once', () async {
    await _saveCredentials();
    await PluginCredentialsStore.instance.saveToken('test-rule', 'stale');
    final sender = _ScriptedSender([
      NetworkException(
        type: NetworkExceptionType.badResponse,
        message: '401',
        statusCode: 401,
      ),
      '{"data":{"token":"tok-2"}}',
      '{"data":[]}',
    ]);
    final executor = DefaultRuleRequestExecutor(textSender: sender.call);
    final output = await executor.execute(
        _request('https://example.org/api/search'), _config(auth: login));

    expect(output, '{"data":[]}');
    expect(sender.sent.first.headers['authorization'], 'stale');
    expect(sender.loginCalls, 1);
    expect(sender.sent.last.headers['authorization'], 'tok-2');
    expect(PluginCredentialsStore.instance.tokenFor('test-rule'), 'tok-2');
  });

  test('a non-refreshable status propagates without a second login', () async {
    await _saveCredentials();
    await PluginCredentialsStore.instance.saveToken('test-rule', 'tok-1');
    final sender = _ScriptedSender([
      NetworkException(
        type: NetworkExceptionType.badResponse,
        message: '500',
        statusCode: 500,
      ),
    ]);
    final executor = DefaultRuleRequestExecutor(textSender: sender.call);
    await expectLater(
      executor.execute(
          _request('https://example.org/api/search'), _config(auth: login)),
      throwsA(isA<NetworkException>()),
    );
    expect(sender.loginCalls, 0);
  });

  test('a failed login surfaces as RuleAuthFailedException', () async {
    await _saveCredentials(password: 'wrong');
    final sender = _ScriptedSender(['{"error":"bad credentials"}']);
    final executor = DefaultRuleRequestExecutor(textSender: sender.call);
    await expectLater(
      executor.execute(
          _request('https://example.org/api/search'), _config(auth: login)),
      throwsA(isA<RuleAuthFailedException>()),
    );
    expect(PluginCredentialsStore.instance.tokenFor('test-rule'), isNull);
  });

  test('tokenPrefix is prepended to the header value', () async {
    await _saveCredentials();
    final prefixed = ApiAuthConfig(
      login: ApiRequestConfig(
        method: 'POST',
        url: 'https://example.org/api/auth/login',
      ),
      tokenPrefix: 'Bearer ',
    );
    final sender = _ScriptedSender([
      '{"data":{"token":"abc"}}',
      '{}',
    ]);
    final executor = DefaultRuleRequestExecutor(textSender: sender.call);
    await executor.execute(
        _request('https://example.org/api/search'), _config(auth: prefixed));
    expect(sender.sent.last.headers['authorization'], 'Bearer abc');
  });
}
