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
        // ECH 模式下还是连同一个主机，所以令牌仍只发给 Bangumi。
        final accelerated = await _echService.get(
          source.replace(scheme: 'https').toString(),
          headers: _withToken(headers, token),
        );
        return _retryWithToken(accelerated, source, token, headers);

      case ImageAcceleration.mirror:
        final target = BangumiImageUrlRewriter.rewrite(source);
        if (target == source) return _fetch(source, _withToken(headers, token));
        // wsrv.nl 是第三方，绝不能把访问令牌转发给它。
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

  /// Bangumi 只对已鉴权的调用方提供 R18 封面。wsrv 镜像是匿名转发的，
  /// 会返回 404，所以带上令牌把原始地址再请求一次；
  /// 若那样也失败，就沿用加速源的结果。
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
