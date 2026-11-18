import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _RecordingAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Future<ResponseBody> Function(RequestOptions, int) respond;

  _RecordingAdapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final index = requests.length;
    requests.add(options);
    return respond(options, index);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  late Directory directory;
  late PathProviderPlatform originalPaths;
  late _RecordingAdapter adapter;

  setUpAll(() async {
    Logger.level = Level.off;
    final temporaryRoot = await Directory('tmp').create(recursive: true);
    directory = await temporaryRoot.createTemp('kazumi_retry_test_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  setUp(() {
    DioFactory.reset();
    adapter = _RecordingAdapter((_, _) async => _json({'data': []}));
    DioFactory.bangumiDio.httpClientAdapter.close();
    DioFactory.bangumiDio.httpClientAdapter = adapter;
  });

  tearDownAll(() async {
    DioFactory.bangumiDio.close(force: true);
    DioFactory.reset();
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  DioException netError(RequestOptions request, DioExceptionType type) =>
      DioException(requestOptions: request, type: type);

  for (final type in [
    DioExceptionType.connectionError,
    DioExceptionType.connectionTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.sendTimeout,
  ]) {
    test('trends first page retries once after $type then succeeds', () async {
      adapter.respond = (request, index) async {
        if (index == 0) throw netError(request, type);
        return _json({
          'data': [
            {
              'subject': {'id': 1, 'name': 'A', 'rating': {}, 'images': {}},
            },
          ],
        });
      };

      final result = await BangumiApi.getBangumiTrendsList(offset: 0);

      expect(adapter.requests, hasLength(2));
      expect(result, hasLength(1));
      expect(result.single.id, 1);
      expect(
        adapter.requests[0].uri.toString(),
        adapter.requests[1].uri.toString(),
        reason: 'retry must reuse the exact same URL and params',
      );
    });
  }

  test(
    'trends stops after two attempts when transient error persists',
    () async {
      adapter.respond = (request, index) async {
        throw netError(request, DioExceptionType.connectionError);
      };

      final result = await BangumiApi.getBangumiTrendsList(offset: 0);

      expect(adapter.requests, hasLength(2));
      expect(result, isEmpty);
    },
  );

  test('trends healthy first attempt performs a single request', () async {
    final result = await BangumiApi.getBangumiTrendsList(offset: 0);

    expect(adapter.requests, hasLength(1));
    expect(result, isEmpty);
  });

  test('trends legal empty result performs a single request', () async {
    adapter.respond = (_, _) async => _json({'data': []});

    final result = await BangumiApi.getBangumiTrendsList(offset: 0);

    expect(adapter.requests, hasLength(1));
    expect(result, isEmpty);
  });

  for (final type in [
    DioExceptionType.badCertificate,
    DioExceptionType.badResponse,
    DioExceptionType.cancel,
  ]) {
    test('trends does not retry $type', () async {
      adapter.respond = (request, index) async {
        if (index == 0) {
          throw netError(request, type);
        }
        return _json({'data': []});
      };

      await BangumiApi.getBangumiTrendsList(offset: 0);

      expect(adapter.requests, hasLength(1));
    });
  }

  test('trends parse error does not retry', () async {
    adapter.respond = (_, _) async => _json({
      'data': [
        {'subject': 'not-a-map'},
      ],
    });

    final result = await BangumiApi.getBangumiTrendsList(offset: 0);

    expect(adapter.requests, hasLength(1));
    expect(result, isEmpty);
  });

  test('trends paginated failure is not retried', () async {
    adapter.respond = (request, index) async {
      throw netError(request, DioExceptionType.connectionError);
    };

    final result = await BangumiApi.getBangumiTrendsList(offset: 24);

    expect(adapter.requests, hasLength(1));
    expect(result, isEmpty);
    expect(
      adapter.requests.single.uri.queryParameters['offset'],
      '24',
      reason: 'pagination offset must be preserved',
    );
  });

  test(
    'mirror first page retries once after transient error then succeeds',
    () async {
      adapter.respond = (request, index) async {
        if (index == 0) {
          throw netError(request, DioExceptionType.connectionError);
        }
        return _json([
          {'id': 2, 'name': 'B', 'rating': {}, 'images': {}},
        ]);
      };

      final result = await BangumiApi.getBangumiMirrorPopularSubjects(
        offset: 0,
      );

      expect(adapter.requests, hasLength(2));
      expect(result, hasLength(1));
      expect(result.single.id, 2);
      expect(
        adapter.requests[0].uri.toString(),
        adapter.requests[1].uri.toString(),
        reason: 'retry must reuse the exact same URL and params',
      );
    },
  );

  test('mirror paginated failure is not retried', () async {
    adapter.respond = (request, index) async {
      throw netError(request, DioExceptionType.connectionError);
    };

    final result = await BangumiApi.getBangumiMirrorPopularSubjects(offset: 24);

    expect(adapter.requests, hasLength(1));
    expect(result, isEmpty);
    expect(adapter.requests.single.uri.queryParameters['offset'], '24');
  });
}
