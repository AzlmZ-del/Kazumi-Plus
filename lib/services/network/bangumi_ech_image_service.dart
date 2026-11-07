import 'dart:io' show HttpClientResponseCompressionState;

import 'package:ech_http/ech_http.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:kazumi/services/network/bangumi_ech_resolver.dart';
import 'package:kazumi/services/network/image_file_response.dart';
import 'package:kazumi/utils/constants.dart' show bangumiHTTPHeader;

class BangumiEchImageService extends FileService {
  BangumiEchImageService({required Uri? Function(Uri) proxyForUrl})
    : _proxyForUrl = proxyForUrl;

  final Uri? Function(Uri) _proxyForUrl;
  final _current = <(Uri?, Uri?), _EchSession>{};
  final _sessions = <_EchSession>{};
  bool _closed = false;

  _EchSession _sessionFor(Uri uri) {
    final proxies = (
      _proxyForUrl(uri),
      _proxyForUrl(BangumiEchResolver.endpoint),
    );
    return _current.putIfAbsent(proxies, () {
      final bootstrap = EchClient(proxy: proxies.$2);
      try {
        final images = EchClient(
          proxy: proxies.$1,
          resolver: BangumiEchResolver.create(bootstrap),
        );
        final session = _EchSession(bootstrap, images);
        _sessions.add(session);
        return session;
      } catch (_) {
        bootstrap.close();
        rethrow;
      }
    });
  }

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    if (_closed) throw StateError('ECH image service is closed');
    final uri = Uri.parse(url);
    final session = _sessionFor(uri);
    session.active++;
    final EchResponse response;
    try {
      final request = http.Request('GET', uri);
      request.headers['user-agent'] = bangumiHTTPHeader['user-agent']!;
      if (headers != null) request.headers.addAll(headers);
      response = await session.images.send(request);
    } catch (_) {
      _release(session);
      rethrow;
    }
    return createImageFileResponse(
      response,
      // ECH 解压后仍是原始字节长度，解码后的实际尺寸未知。
      contentLength:
          response.compressionState ==
              HttpClientResponseCompressionState.decompressed
          ? null
          : response.contentLength,
      onComplete: () => _release(session),
    );
  }

  void _release(_EchSession session) {
    session.active--;
    if (session.retired && session.active == 0 && _sessions.remove(session)) {
      session.close();
    }
  }

  /// 新请求走新连接；已经在传的图片流可以正常收尾。
  void reset() {
    _current.clear();
    for (final session in _sessions.toList()) {
      session.retired = true;
      if (session.active == 0) {
        _sessions.remove(session);
        session.close();
      }
    }
  }

  void close() {
    _closed = true;
    _current.clear();
    for (final session in _sessions) {
      session.close();
    }
    _sessions.clear();
  }
}

class _EchSession {
  _EchSession(this.bootstrap, this.images);

  final EchClient bootstrap;
  final EchClient images;
  int active = 0;
  bool retired = false;

  void close() {
    images.close();
    bootstrap.close();
  }
}
