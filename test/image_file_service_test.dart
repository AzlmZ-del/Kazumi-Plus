import 'dart:convert';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:kazumi/services/network/bangumi_ech_image_service.dart';
import 'package:kazumi/services/network/image_acceleration.dart';
import 'package:kazumi/services/network/image_file_response.dart';
import 'package:kazumi/services/network/image_file_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  late Directory directory;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('kazumi_image_service_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  setUp(() async {
    await GStorage.putSetting(SettingsKeys.bangumiAccessToken, '');
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  ImageFileService buildService(
    ImageAcceleration mode,
    http.Client client, {
    BangumiEchImageService? ech,
  }) {
    final service = ImageFileService(
      acceleration: () => mode,
      clientFactory: () => client,
      echService: ech ?? _FakeEchService(),
    );
    addTearDown(service.close);
    return service;
  }

  test('direct mode attaches the token for Bangumi images', () async {
    await GStorage.putSetting(SettingsKeys.bangumiAccessToken, 'secret');
    final client = _RecordingClient();
    final service = buildService(ImageAcceleration.direct, client);

    final response = await service.get(
      'https://api.bgm.tv/v0/subjects/74435/image?type=large',
    );

    expect(client.requests.single.headers['Authorization'], 'Bearer secret');
    expect(response.statusCode, 200);
  });

  test('direct mode leaves non-Bangumi images untouched', () async {
    await GStorage.putSetting(SettingsKeys.bangumiAccessToken, 'secret');
    final client = _RecordingClient();
    final service = buildService(ImageAcceleration.direct, client);

    await service.get('https://example.com/cover.jpg');

    expect(
      client.requests.single.headers.containsKey('Authorization'),
      isFalse,
    );
  });

  test('mirror mode never sends the token to the image proxy', () async {
    await GStorage.putSetting(SettingsKeys.bangumiAccessToken, 'secret');
    final client = _RecordingClient();
    final service = buildService(ImageAcceleration.mirror, client);

    await service.get(
      'https://api.bgm.tv/v0/subjects/400602/image?type=large',
    );

    expect(client.requests.single.url.host, 'wsrv.nl');
    expect(client.requests.single.headers.containsKey('Authorization'), isFalse);
  });

  test('mirror mode retries the original URL when the proxy fails', () async {
    await GStorage.putSetting(SettingsKeys.bangumiAccessToken, 'secret');
    final client = _RecordingClient(failing: {'wsrv.nl'});
    final service = buildService(ImageAcceleration.mirror, client);

    final response = await service.get(
      'https://api.bgm.tv/v0/subjects/74435/image?type=large',
    );

    expect(client.requests.length, 2);
    expect(client.requests.first.url.host, 'wsrv.nl');
    expect(client.requests.last.url.host, 'api.bgm.tv');
    expect(client.requests.last.headers['Authorization'], 'Bearer secret');
    expect(response.statusCode, 200);
  });

  test('mirror mode keeps the proxy failure when no token is saved', () async {
    final client = _RecordingClient(failing: {'wsrv.nl'});
    final service = buildService(ImageAcceleration.mirror, client);

    final response = await service.get(
      'https://api.bgm.tv/v0/subjects/74435/image?type=large',
    );

    expect(client.requests.length, 1);
    expect(response.statusCode, 404);
  });

  test('ech mode keeps the token because the host does not change', () async {
    await GStorage.putSetting(SettingsKeys.bangumiAccessToken, 'secret');
    final ech = _FakeEchService();
    final service = buildService(
      ImageAcceleration.ech,
      _RecordingClient(),
      ech: ech,
    );

    await service.get('https://lain.bgm.tv/pic/cover/l/74435.jpg');

    expect(ech.requests.single.headers['Authorization'], 'Bearer secret');
  });
}

class _RecordingClient extends http.BaseClient {
  _RecordingClient({this.failing = const {}});

  final Set<String> failing;
  final requests = <http.Request>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request as http.Request);
    final status = failing.contains(request.url.host) ? 404 : 200;
    return http.StreamedResponse(
      Stream.value(utf8.encode('bytes')),
      status,
      contentLength: 5,
    );
  }
}

class _FakeEchService extends FileService
    implements BangumiEchImageService {
  final requests = <http.Request>[];

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final request = http.Request('GET', Uri.parse(url));
    if (headers != null) request.headers.addAll(headers);
    requests.add(request);
    return createImageFileResponse(
      http.StreamedResponse(Stream.value(const []), 200, contentLength: 0),
      contentLength: 0,
      onComplete: () {},
    );
  }

  @override
  void reset() {}

  @override
  void close() {}
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}
