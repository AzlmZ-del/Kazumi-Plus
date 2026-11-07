import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:kazumi/services/network/bangumi_ech_resolver.dart';
import 'package:kazumi/services/network/bangumi_mirror_signature.dart';

const _echRequestKey = 'bangumiEch';

/// 写进 [RequestOptions.extra]，让请求即使选了镜像也仍走官方主机。
/// 调用方用它重试镜像提供不了的接口——镜像转发时不带凭据，
/// 所以像 R18 评论这类需要主体权限的数据会返回上游错误。
const bangumiForceOfficialKey = 'bangumiForceOfficial';

class BangumiAccelerationInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra.remove(_echRequestKey);
    if (options.extra.remove(bangumiForceOfficialKey) == true) {
      handler.next(options);
      return;
    }
    final uri = options.uri;
    if (ApiEndpoints.bangumiPublicApiHosts.contains(uri.host)) {
      switch (BangumiAcceleration.current) {
        case BangumiAcceleration.direct:
          break;
        case BangumiAcceleration.ech:
          options.path = uri.replace(scheme: 'https').toString();
          options.queryParameters = {};
          options.extra[_echRequestKey] = true;
        case BangumiAcceleration.mirror:
          // 构建里没有凭据时，需要签名的接口在镜像上会返回 401，
          // 而官方主机是允许匿名访问的。所以这些路径留在官方主机上，
          // 而不是返回空数据。
          if (!hasBangumiMirrorCredentials &&
              isSignatureProtectedBangumiPath(options.method, uri.path)) {
            KazumiLogger().d(
                'Bangumi mirror: skipping ${options.method} ${uri.path} (no credentials)');
            break;
          }
          options.path =
              ApiEndpoints.bangumiMirrorDomain +
              uri.path +
              (uri.hasQuery ? '?${uri.query}' : '');
          options.queryParameters = {};
          KazumiLogger().d('Bangumi mirror: ${options.path}');
      }
    }
    handler.next(options);
  }
}

class BangumiEchAdapter implements HttpClientAdapter {
  BangumiEchAdapter({
    required HttpClientAdapter fallback,
    required NetworkConfig config,
  }) : _fallback = fallback,
       _config = config;

  final HttpClientAdapter _fallback;
  final NetworkConfig _config;
  final _resolvers = <Uri?, RetryingEchResolver>{};
  final _clients = <(Uri?, Uri?, Duration, Duration), EchClient>{};
  final _activeRequests = <Completer<void>>{};
  bool _closed = false;

  EchClient _clientFor(RequestOptions options) {
    final proxy = _config.proxyForUri(options.uri);
    final dohProxy = _config.proxyForUri(BangumiEchResolver.endpoint);
    final connectTimeout = _positive(
      options.connectTimeout,
      _config.connectTimeout,
    );
    final timeout =
        connectTimeout +
        _positive(options.receiveTimeout, _config.receiveTimeout) +
        _positive(options.sendTimeout, const Duration(seconds: 12));
    // 原生超时是客户端级别的；只有设置相同的客户端才共用一个连接池。
    return _clients.putIfAbsent(
      (proxy, dohProxy, connectTimeout, timeout),
      () => EchClient(
        proxy: proxy,
        resolver: _resolvers.putIfAbsent(
          dohProxy,
          () => BangumiEchResolver.create(EchClient(proxy: dohProxy)),
        ),
        connectTimeout: connectTimeout,
        timeout: timeout,
      ),
    );
  }

  static Duration _positive(Duration? value, Duration fallback) =>
      value != null && value > Duration.zero ? value : fallback;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('Bangumi ECH adapter is closed');
    if (options.extra[_echRequestKey] != true) {
      return _fallback.fetch(options, requestStream, cancelFuture);
    }

    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    cancelFuture?.then((_) => cancel());
    _activeRequests.add(abort);
    void release() {
      if (!_activeRequests.remove(abort)) return;
      cancel();
      if (_closed && _activeRequests.isEmpty) _closeClients();
    }

    try {
      final client = _clientFor(options);
      final request =
          _EchRequest(options.method, options.uri, requestStream, abort.future)
            ..followRedirects = options.followRedirects
            ..maxRedirects = options.maxRedirects
            ..persistentConnection = options.persistentConnection;
      for (final entry in options.headers.entries) {
        final value = entry.value;
        if (value != null) {
          request.headers[entry.key] = value is Iterable
              ? value.join(', ')
              : value.toString();
        }
      }
      // 原生连接超时不含 DoH 解析耗时。
      final timeout =
          _positive(options.connectTimeout, _config.connectTimeout) +
          _positive(options.receiveTimeout, _config.receiveTimeout);
      final response = await client
          .send(request)
          .timeout(
            timeout,
            onTimeout: () {
              cancel();
              throw DioException.receiveTimeout(
                timeout: timeout,
                requestOptions: options,
              );
            },
          );
      return ResponseBody(
        _responseStream(response.stream, options, release),
        response.statusCode,
        headers: response.headers.map((key, value) => MapEntry(key, [value])),
        statusMessage: response.reasonPhrase,
        isRedirect: response.isRedirect,
        onClose: release,
      );
    } catch (error, stackTrace) {
      release();
      throw _mapError(error, stackTrace, options);
    }
  }

  Stream<Uint8List> _responseStream(
    Stream<List<int>> stream,
    RequestOptions options,
    void Function() release,
  ) async* {
    try {
      await for (final chunk in stream) {
        yield chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      }
    } catch (error, stackTrace) {
      throw _mapError(error, stackTrace, options);
    } finally {
      release();
    }
  }

  DioException _mapError(
    Object error,
    StackTrace stack,
    RequestOptions options,
  ) {
    if (error is DioException) return error;
    if (error is http.RequestAbortedException) {
      return DioException.requestCancelled(
        requestOptions: options,
        reason: error,
        stackTrace: stack,
      );
    }
    if (error is EchException && error.nativeCode == 28) {
      return DioException.receiveTimeout(
        requestOptions: options,
        timeout: options.receiveTimeout ?? _config.receiveTimeout,
        error: error,
      );
    }
    return DioException.connectionError(
      requestOptions: options,
      reason: error.toString(),
      error: error,
      stackTrace: stack,
    );
  }

  void _closeClients() {
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
    for (final resolver in _resolvers.values) {
      resolver.client.close();
    }
    _resolvers.clear();
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    _fallback.close(force: force);
    if (force || _activeRequests.isEmpty) _closeClients();
  }
}

class _EchRequest extends http.BaseRequest with http.Abortable {
  _EchRequest(super.method, super.url, this._stream, this.abortTrigger);

  final Stream<Uint8List>? _stream;
  @override
  final Future<void> abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_stream ?? const Stream.empty());
  }
}
