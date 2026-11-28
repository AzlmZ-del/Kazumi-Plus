import 'dart:io' show HttpClientResponseCompressionState;

import 'package:ech_http/ech_http.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:kazumi/request/core/ech_transport.dart';
import 'package:kazumi/services/network/image_file_response.dart';
import 'package:kazumi/utils/constants.dart' show bangumiHTTPHeader;

class BangumiEchImageService extends FileService {
  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse(url);
    final request = http.Request('GET', uri);
    request.headers['user-agent'] = bangumiHTTPHeader['user-agent']!;
    if (headers != null) request.headers.addAll(headers);

    final lease = EchTransport.lease(uri);
    final EchResponse response;
    try {
      response = await lease.send(request);
    } catch (_) {
      lease.release();
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
      onComplete: lease.release,
    );
  }
}
