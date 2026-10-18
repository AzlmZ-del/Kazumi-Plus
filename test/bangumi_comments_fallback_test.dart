import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/network/bangumi_mirror_signature.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Records every outgoing URL instead of hitting the network. Swapping the
/// adapter keeps the real interceptor chain in place, so the recorded host is
/// exactly what a release build would contact.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({this.status = 200});

  final int status;
  final List<String> urls = [];
  final List<Map<String, dynamic>> headers = [];

  /// Statuses to answer with, in order. Falls back to [status] afterwards.
  List<int> statuses = const [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final index = urls.length;
    urls.add(options.uri.toString());
    headers.add(Map<String, dynamic>.from(options.headers));
    final effective =
        index < statuses.length ? statuses[index] : status;
    final body = effective == 200
        ? jsonEncode({'data': [], 'total': 0})
        : jsonEncode({'error': 'nope'});
    return ResponseBody.fromString(
      body,
      effective,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory directory;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('kazumi_probe_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    DioFactory.reset();
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  _RecordingAdapter install({int status = 200}) {
    DioFactory.reset();
    final adapter = _RecordingAdapter(status: status);
    DioFactory.bangumiDio.httpClientAdapter = adapter;
    return adapter;
  }

  setUp(() async {
    await GStorage.putSetting(SettingsKeys.bangumiAcceleration, 'mirror');
    await GStorage.putSetting(SettingsKeys.bangumiAccessToken, 'tok');
    await GStorage.putSetting(SettingsKeys.bangumiSyncEnable, true);
  });

  // The mirror branch only engages when the build carries the signing
  // credentials, which arrive through --dart-define. Without them the transport
  // deliberately keeps signed paths on the official host, so these two cases
  // have nothing to observe.
  final mirrorSkip = hasBangumiMirrorCredentials
      ? false
      : 'requires --dart-define=KAZUMI_APPID/KAZUMI_KEY';

  test('mirror mode sends an ordinary comments request to the mirror', () async {
    final adapter = install();

    await BangumiApi.getBangumiCommentsByID(253);

    expect(adapter.urls, hasLength(1),
        reason: 'a healthy mirror answer must not be retried');
    expect(Uri.parse(adapter.urls.single).host, 'api.kazumi.fyi');
    expect(adapter.headers.single.containsKey('X-Signature'), isTrue,
        reason: 'the mirror request must be signed');
  }, skip: mirrorSkip);

  test('a mirror 502 falls back to the official host with the token', () async {
    final adapter = install(status: 200);
    // First request (the mirror) fails the way R18 subjects do; the retry
    // succeeds on the official host.
    adapter.statuses = const [502, 200];

    await BangumiApi.getBangumiCommentsByID(74435);

    expect(adapter.urls, hasLength(2),
        reason: 'the mirror failure should be retried once on the official host');
    expect(Uri.parse(adapter.urls[0]).host, 'api.kazumi.fyi');
    expect(Uri.parse(adapter.urls[1]).host, 'next.bgm.tv');
    expect(adapter.headers[1]['Authorization'], 'Bearer tok',
        reason: 'the retry must authenticate, R18 comments need a token');
  }, skip: mirrorSkip);

  test('direct mode never touches the mirror', () async {
    await GStorage.putSetting(SettingsKeys.bangumiAcceleration, 'direct');
    final adapter = install();

    await BangumiApi.getBangumiCommentsByID(253);

    expect(Uri.parse(adapter.urls.single).host, 'next.bgm.tv');
    expect(adapter.headers.single['Authorization'], 'Bearer tok');
  });

  test('without credentials a signed path stays on the official host', () async {
    if (hasBangumiMirrorCredentials) {
      // Covered by the mirror cases above; keep the assertion meaningful only
      // for the credential-less build this test exists for.
      return;
    }
    final adapter = install();

    await BangumiApi.getBangumiCommentsByID(253);

    expect(Uri.parse(adapter.urls.single).host, 'next.bgm.tv',
        reason: 'an unsigned mirror request would answer 401');
  });
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;
}
