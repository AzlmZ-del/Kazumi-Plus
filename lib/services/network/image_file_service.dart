import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:kazumi/services/network/bangumi_ech_image_service.dart';
import 'package:kazumi/services/network/bangumi_image_url_rewriter.dart';
import 'package:kazumi/services/network/image_acceleration.dart';
import 'package:kazumi/services/network/image_file_response.dart';
import 'package:kazumi/services/storage/storage.dart';

class ImageFileService extends FileService {
  ImageFileService({
    required ImageAcceleration Function() acceleration,
    required http.Client Function() clientFactory,
    required BangumiEchImageService echService,
  }) : _acceleration = acceleration,
       _clientFactory = clientFactory,
       _echService = echService;

  final ImageAcceleration Function() _acceleration;
  final http.Client Function() _clientFactory;
  final BangumiEchImageService _echService;
  final _clients = <http.Client>{};
  bool _closed = false;

  void resetNetworkClients() => _echService.reset();

  void close() {
    _closed = true;
    _echService.close();
    for (final client in _clients) {
      client.close();
    }
    _clients.clear();
  }

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    if (_closed) throw StateError('Image file service is closed');
    final mode = _acceleration();
    final source = Uri.parse(url);
    final token =
        BangumiImageUrlRewriter.isBangumiImage(source)
            ? GStorage.getSetting(SettingsKeys.bangumiAccessToken).trim()
            : '';

    switch (mode) {
      case ImageAcceleration.direct:
        return _fetch(source, _withToken(headers, token));

      case ImageAcceleration.ech:
        if (!BangumiImageUrlRewriter.isBangumiImage(source)) {
          return _fetch(source, headers);
        }
        // ECH keeps talking to the same host, so the token stays with Bangumi.
        final accelerated = await _echService.get(
          source.replace(scheme: 'https').toString(),
          headers: _withToken(headers, token),
        );
        return _retryWithToken(accelerated, source, token, headers);

      case ImageAcceleration.mirror:
        final target = BangumiImageUrlRewriter.rewrite(source);
        if (target == source) return _fetch(source, _withToken(headers, token));
        // wsrv.nl is a third party; never forward the access token to it.
        final accelerated = await _fetch(target, _withoutToken(headers));
        return _retryWithToken(accelerated, source, token, headers);
    }
  }

  static Map<String, String>? _withToken(
    Map<String, String>? headers,
    String token,
  ) {
    if (token.isEmpty) return headers;
    if (headers != null && headers.containsKey('Authorization')) return headers;
    return {...?headers, 'Authorization': 'Bearer $token'};
  }

  static Map<String, String>? _withoutToken(Map<String, String>? headers) {
    if (headers == null || !headers.containsKey('Authorization')) return headers;
    return {...headers}..remove('Authorization');
  }

  /// Bangumi serves R18 covers only to authenticated callers. The wsrv mirror
  /// forwards anonymously and answers 404, so replay the original URL with the
  /// token and keep the accelerated result when that fails as well.
  Future<FileServiceResponse> _retryWithToken(
    FileServiceResponse accelerated,
    Uri source,
    String token,
    Map<String, String>? headers,
  ) async {
    if (_isSuccess(accelerated.statusCode) || token.isEmpty) {
      return accelerated;
    }
    final retry = await _fetch(source, _withToken(headers, token));
    return _isSuccess(retry.statusCode) ? retry : accelerated;
  }

  static bool _isSuccess(int statusCode) =>
      statusCode == 200 || statusCode == 202;

  Future<FileServiceResponse> _fetch(
    Uri uri,
    Map<String, String>? headers,
  ) async {
    final client = _clientFactory();
    _clients.add(client);
    final http.StreamedResponse response;
    try {
      final request = http.Request('GET', uri);
      if (headers != null) request.headers.addAll(headers);
      response = await client.send(request);
    } catch (_) {
      _release(client);
      rethrow;
    }
    return createImageFileResponse(
      response,
      contentLength: response.contentLength,
      onComplete: () => _release(client),
    );
  }

  void _release(http.Client client) {
    if (_clients.remove(client)) client.close();
  }
}
