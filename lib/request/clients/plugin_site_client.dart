import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:kazumi/services/network/source_network_service.dart';
import 'package:kazumi/utils/http_headers.dart';

class PluginSiteClient {
  PluginSiteClient({
    SourceNetworkResolver? resolver,
    Dio Function(SourceNetworkRoute route)? dioForRoute,
  }) : _resolver = resolver ?? SourceNetworkService.resolver,
       _dioForRoute = dioForRoute ?? DioFactory.pluginForRoute;

  static final PluginSiteClient instance = PluginSiteClient();

  final SourceNetworkResolver _resolver;
  final Dio Function(SourceNetworkRoute route) _dioForRoute;

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
    try {
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      final resolving = _resolver.resolve(
        directConnection: directConnection,
        target: Uri.parse(url),
      );
      final route = cancelToken == null
          ? await resolving
          : await Future.any<SourceNetworkRoute>([
              resolving,
              cancelToken.whenCancel.then<SourceNetworkRoute>(
                (error) => throw error,
              ),
            ]);
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      final requestHeaders = _headers(headers);
      if (data != null) {
        switch (bodyType) {
          case 'json':
            requestHeaders.putIfAbsent(
              'content-type',
              () => 'application/json',
            );
            break;
          case 'form':
            requestHeaders.putIfAbsent(
              'content-type',
              () => Headers.formUrlEncodedContentType,
            );
            break;
        }
      }
      final response = await _dioForRoute(route).request<String>(
        url,
        queryParameters: queryParameters,
        data: data,
        options: Options(
          method: method,
          responseType: ResponseType.plain,
          headers: requestHeaders,
        ),
        cancelToken: cancelToken,
      );
      return response.data ?? '';
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Map<String, dynamic> _headers(Map<String, dynamic> headers) {
    return {
      'user-agent': getRandomHttpUA(),
      'accept-language': getRandomAcceptedLanguage(),
      'connection': 'keep-alive',
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    };
  }
}
