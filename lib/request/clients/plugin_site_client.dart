import 'dart:io';

import 'package:dio/dio.dart';
import 'package:kazumi/request/clients/direct_http_client.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:kazumi/utils/http_headers.dart';

class PluginSiteClient {
  PluginSiteClient._();

  static final PluginSiteClient instance = PluginSiteClient._();

  Future<String> requestText(
    String url, {
    required String method,
    Map<String, dynamic> headers = const {},
    Map<String, dynamic> queryParameters = const {},
    Object? data,
    CancelToken? cancelToken,
    bool directConnection = false,
    String bodyType = 'json',
  }) async {
    // Android + 直连：系统可能是 TUN 型 VPN（Clash 之类），内核按 uid 分流，
    // Dio 的 findProxy 管不着。这时改走原生 requestNetwork(NOT_VPN) 通道，
    // 才能真正绕开隧道。没有 VPN 时仍用 Dio，保留 keep-alive 与超时配置。
    if (directConnection && Platform.isAndroid) {
      if (await DirectHttpClient.isVpnActive()) {
        return DirectHttpClient.request(
          url: _withQuery(url, queryParameters),
          method: method,
          headers: _headers(headers),
          body: data,
          bodyType: bodyType,
        );
      }
    }
    try {
      final dio = directConnection
          ? DioFactory.pluginDirectDio
          : DioFactory.pluginDio;
      final response = await dio.request<String>(
        url,
        queryParameters: queryParameters,
        data: data,
        options: Options(
          method: method,
          responseType: ResponseType.plain,
          headers: _headers(headers),
        ),
        cancelToken: cancelToken,
      );
      return response.data ?? '';
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  /// 原生通道没有 queryParameters 参数，这里把查询串拼进 URL。
  String _withQuery(String url, Map<String, dynamic> queryParameters) {
    if (queryParameters.isEmpty) return url;
    final uri = Uri.parse(url);
    final merged = <String, dynamic>{
      ...uri.queryParameters,
      ...queryParameters.map((key, value) => MapEntry(key, '$value')),
    };
    return uri.replace(queryParameters: merged).toString();
  }

  Map<String, dynamic> _headers(Map<String, dynamic> headers) {
    return {
      // 原生 HTTP 请求用非浏览器 UA：浏览器 UA 配 BoringSSL 指纹会被
      // Cloudflare 判为伪装并直接 403。规则显式配了 UA 时由 headers 覆盖。
      'user-agent': getRandomHttpUA(),
      'Accept-Language': getRandomAcceptedLanguage(),
      'Connection': 'keep-alive',
      ...headers,
    };
  }
}
