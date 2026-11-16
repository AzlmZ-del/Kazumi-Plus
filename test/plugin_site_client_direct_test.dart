import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/clients/plugin_site_client.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/network/source_network_route.dart';

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({
    this.status = 200,
    this.body = 'ok',
    this.responseHeaders = const {},
  });

  final int status;
  final String body;
  final Map<String, List<String>> responseHeaders;
  final requests = <RequestOptions>[];
  final payloads = <String>[];
  Completer<void>? pending;
  final started = Completer<void>();
  bool cancelled = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    payloads.add(utf8.decode(bytes));
    if (!started.isCompleted) started.complete();
    final waiting = pending;
    if (waiting != null) {
      await Future.any<void>([
        waiting.future,
        if (cancelFuture != null)
          cancelFuture.then<void>((_) {
            cancelled = true;
            throw DioException.requestCancelled(
              requestOptions: options,
              reason: 'cancelled',
            );
          }),
      ]);
    }
    return ResponseBody.fromString(body, status, headers: responseHeaders);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _RecordingAdapter adapter;
  late Dio dio;
  late List<SourceNetworkRoute> routes;

  PluginSiteClient client({SourceNetworkResolver? resolver}) =>
      PluginSiteClient(
        resolver:
            resolver ??
            SourceNetworkResolver(
              isAndroid: true,
              isVpnActive: () async => true,
              startGateway: () async => 9000,
              defaultRoute: (_) =>
                  SourceNetworkRoute.proxy(Uri.parse('http://127.0.0.1:7897')),
            ),
        dioForRoute: (route) {
          routes.add(route);
          return dio;
        },
      );

  setUp(() {
    adapter = _RecordingAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    routes = [];
  });
  tearDown(() => dio.close(force: true));

  test('Android VPN direct search and chapters still use Dio', () async {
    final site = client();
    expect(
      await site.requestText(
        'https://example.com/search',
        method: 'GET',
        queryParameters: {'keyword': '动画'},
        directConnection: true,
      ),
      'ok',
    );
    expect(
      await site.requestText(
        'https://example.com/detail',
        method: 'GET',
        directConnection: true,
      ),
      'ok',
    );
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.first.uri.queryParameters['keyword'], '动画');
    expect(
      routes.every((route) => route.mode == SourceNetworkMode.directGateway),
      isTrue,
    );
  });

  test(
    'JSON and form bodies keep Dio serialization and rule headers',
    () async {
      final site = client();
      await site.requestText(
        'https://example.com/login',
        method: 'POST',
        directConnection: true,
        data: {'keyword': '动画'},
        headers: {'User-Agent': 'rule-agent'},
      );
      expect(jsonDecode(adapter.payloads.first), {'keyword': '动画'});
      expect(adapter.requests.first.headers['user-agent'], 'rule-agent');
      expect(
        adapter.requests.first.headers['content-type'],
        'application/json',
      );
      await site.requestText(
        'https://example.com/login',
        method: 'POST',
        directConnection: true,
        data: {'name': 'a b'},
        bodyType: 'form',
      );
      expect(adapter.payloads.last, 'name=a+b');
      expect(
        adapter.requests.last.headers['content-type'],
        Headers.formUrlEncodedContentType,
      );
    },
  );

  test('401 status remains available for authentication refresh', () async {
    adapter = _RecordingAdapter(status: 401, body: '{"error":"expired"}');
    dio.httpClientAdapter = adapter;
    await expectLater(
      client().requestText(
        'https://example.com/detail',
        method: 'GET',
        directConnection: true,
      ),
      throwsA(
        isA<NetworkException>()
            .having(
              (error) => error.type,
              'type',
              NetworkExceptionType.badResponse,
            )
            .having((error) => error.statusCode, 'status', 401),
      ),
    );
  });

  test(
    'challenge status, headers and body remain available to RuleEngine',
    () async {
      adapter = _RecordingAdapter(
        status: 403,
        body: '<html>challenge</html>',
        responseHeaders: {
          'cf-mitigated': ['challenge'],
        },
      );
      dio.httpClientAdapter = adapter;
      try {
        await client().requestText(
          'https://example.com/search',
          method: 'GET',
          directConnection: true,
        );
        fail('Expected a failed response');
      } on NetworkException catch (error) {
        expect(error.type, NetworkExceptionType.badResponse);
        expect(error.statusCode, 403);
        final response = (error.rawError as DioException).response!;
        expect(response.data, '<html>challenge</html>');
        expect(response.headers.value('cf-mitigated'), 'challenge');
      }
    },
  );

  test('cancellation reaches the adapter for direct requests', () async {
    adapter.pending = Completer<void>();
    final cancel = CancelToken();
    final request = client().requestText(
      'https://example.com/detail',
      method: 'GET',
      directConnection: true,
      cancelToken: cancel,
    );
    final expectation = expectLater(
      request,
      throwsA(
        isA<NetworkException>().having(
          (error) => error.type,
          'type',
          NetworkExceptionType.cancel,
        ),
      ),
    );
    await adapter.started.future;
    cancel.cancel('left page');
    await expectation;
    await Future<void>.delayed(Duration.zero);
    expect(adapter.cancelled, isTrue);
    adapter.pending!.complete();
  });

  test(
    'cancellation during gateway startup prevents the HTTP request',
    () async {
      final starting = Completer<int>();
      final started = Completer<void>();
      final resolver = SourceNetworkResolver(
        isAndroid: true,
        isVpnActive: () async => true,
        startGateway: () {
          started.complete();
          return starting.future;
        },
        defaultRoute: (_) => const SourceNetworkRoute.system(),
      );
      final cancel = CancelToken();
      final request = client(resolver: resolver).requestText(
        'https://example.com/search',
        method: 'GET',
        directConnection: true,
        cancelToken: cancel,
      );
      final expectation = expectLater(
        request,
        throwsA(
          isA<NetworkException>().having(
            (error) => error.type,
            'type',
            NetworkExceptionType.cancel,
          ),
        ),
      );
      await started.future;
      cancel.cancel();
      await expectation;
      starting.complete(9000);
      await Future<void>.delayed(Duration.zero);
      expect(adapter.requests, isEmpty);
      expect(routes, isEmpty);
    },
  );

  test(
    'ordinary sources use the configured route, not the direct gateway',
    () async {
      await client().requestText('https://example.com/search', method: 'GET');
      expect(routes.single.mode, SourceNetworkMode.proxy);
      expect(routes.single.proxyUrl, 'http://127.0.0.1:7897');
    },
  );
}
