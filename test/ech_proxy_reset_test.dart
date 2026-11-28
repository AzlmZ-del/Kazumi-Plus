import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/ech_adapter.dart';
import 'package:kazumi/request/core/ech_transport.dart';
import 'package:kazumi/services/network/bangumi_ech_image_service.dart';
import 'package:kazumi/services/network/bangumi_ech_resolver.dart';
import 'package:kazumi/services/network/proxy_aware_image_cache_manager.dart';
import 'package:kazumi/services/network/proxy_manager.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  test(
    'proxy switch refreshes images and Dio without stopping an image',
    () async {
      Logger.level = Level.off;
      final tmp = await Directory('tmp').create(recursive: true);
      final data = await tmp.createTemp('kazumi_ech_proxy_');
      final paths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPaths(data.absolute.path);
      Hive.init(data.absolute.path);
      var cacheInitialized = false;
      addTearDown(() async {
        try {
          if (cacheInitialized) {
            await ProxyAwareImageCacheManager.instance.dispose();
          }
          DioFactory.reset();
          EchTransport.reset();
          await Hive.close();
        } finally {
          PathProviderPlatform.instance = paths;
          await data.delete(recursive: true);
        }
      });
      await GStorage.init();

      final finishFirstImage = Completer<void>();
      final proxyA = await _serve('A', finish: finishFirstImage.future);
      final proxyB = await _serve('B');
      final origin = await _serve('origin');
      addTearDown(() async {
        if (!finishFirstImage.isCompleted) finishFirstImage.complete();
        await Future.wait([
          proxyA.close(force: true),
          proxyB.close(force: true),
          origin.close(force: true),
        ]);
      });
      final url = 'http://127.0.0.1:${origin.port}/cover';
      final images = BangumiEchImageService();

      await _setProxy(proxyA.port);
      await ProxyAwareImageCacheManager.instance.getFileFromCache(url);
      cacheInitialized = true;
      final first = await images.get(url);
      final firstBody = utf8.decoder.bind(first.content).join();

      await _setProxy(proxyB.port);
      final second = await images.get(url);
      expect(await utf8.decoder.bind(second.content).join(), 'B:done');
      final viaDio = await DioFactory.bangumiDio.get<String>(
        url,
        options: Options(extra: echExtra, responseType: ResponseType.plain),
      );
      expect(viaDio.data, 'B:done');

      await GStorage.putSetting(SettingsKeys.proxyEnable, false);
      ProxyManager.clearProxy();
      final direct = await images.get(url);
      expect(await utf8.decoder.bind(direct.content).join(), 'origin:done');
      finishFirstImage.complete();
      expect(await firstBody, 'A:done');
    },
  );

  test(
    'the shared DoH configuration retries and still covers the rules host',
    () async {
      final config = base64.encode([0, 4, 0, 1, 0, 0]);
      var queries = 0;
      final bootstrap = MockClient((_) async {
        queries++;
        if (queries < 3) return http.Response('', 503);
        return http.Response(
          '{"Status":0,"Answer":[{"type":65,"TTL":60,"data":"ech=$config"}]}',
          200,
        );
      });
      addTearDown(bootstrap.close);
      final resolver = BangumiEchResolver.create(
        bootstrap,
        additionalHosts: {ApiEndpoints.ghProxyHost},
      );

      expect(
        await resolver.resolve(Uri.https(ApiEndpoints.ghProxyHost)),
        isNotNull,
      );
      expect(queries, 3);
    },
  );
}

Future<void> _setProxy(int port) async {
  await GStorage.putSetting(SettingsKeys.proxyUrl, '127.0.0.1:$port');
  await GStorage.putSetting(SettingsKeys.proxyEnable, true);
  ProxyManager.applyProxy();
}

Future<HttpServer> _serve(String id, {Future<void>? finish}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    response.bufferOutput = false;
    response.contentLength = '$id:done'.length;
    response.write('$id:');
    await response.flush();
    if (finish != null) await finish;
    response.write('done');
    await response.close();
  });
  return server;
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getTemporaryPath() async => path;
}
