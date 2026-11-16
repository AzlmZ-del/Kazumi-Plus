import 'dart:async';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/source_network_service.dart';
import 'package:kazumi/services/network/source_proxy_lease.dart';
import 'package:kazumi/services/network/source_webview_network.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';

class WebViewVideoSourceService implements IVideoSourceService {
  WebViewVideoSourceService({
    SourceNetworkResolver? resolver,
    VideoWebviewController Function()? webviewFactory,
    Future<SourceProxyLease> Function(
      SourceNetworkRoute, {
      Future<void>? cancelled,
    })?
    acquireLease,
  }) : _resolver = resolver ?? SourceNetworkService.resolver,
       _factory = webviewFactory ?? VideoWebviewControllerFactory.getController,
       _acquireLease = acquireLease ?? SourceWebviewNetwork.acquire;

  final SourceNetworkResolver _resolver;
  final VideoWebviewController Function() _factory;
  final Future<SourceProxyLease> Function(
    SourceNetworkRoute, {
    Future<void>? cancelled,
  })
  _acquireLease;
  VideoWebviewController? _webview;
  SourceNetworkRoute? _route;
  String _userAgent = '';
  bool? _legacyParser;
  StreamSubscription<String>? _logSubscription;
  Future<void>? _resolveTail = Future.value();
  _ResolveRequest? _activeRequest;
  final _logController = StreamController<String>.broadcast();
  Stream<String> get onLog => _logController.stream;

  @override
  Future<VideoSource> resolve(
    String episodeUrl, {
    required bool useLegacyParser,
    int offset = 0,
    Duration timeout = const Duration(seconds: 15),
    String userAgent = '',
    bool directConnection = false,
  }) {
    final previous = _resolveTail;
    if (previous == null) {
      return Future.error(const VideoSourceCancelledException());
    }
    _activeRequest?.cancel();
    final request = _ResolveRequest();
    _activeRequest = request;
    final resolving = previous.then(
      (_) => _runResolve(
        request,
        episodeUrl,
        useLegacyParser: useLegacyParser,
        offset: offset,
        timeout: timeout,
        userAgent: userAgent,
        directConnection: directConnection,
      ),
    );
    _resolveTail = resolving.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return resolving;
  }

  Future<VideoSource> _runResolve(
    _ResolveRequest request,
    String episodeUrl, {
    required bool useLegacyParser,
    required int offset,
    required Duration timeout,
    required String userAgent,
    required bool directConnection,
  }) async {
    SourceProxyLease? lease;
    StreamSubscription<VideoParserEvent>? parserSubscription;
    var didStartLoad = false;
    var navigationSettled = false;
    try {
      request.throwIfNotCurrent(_activeRequest);
      // WebView 未必能强制直连，先折算成本平台能兑现的出口；
      // 同一份结果既给租约也给 WebView 初始化，避免两边出口不一致。
      final route = SourceWebviewNetwork.adaptRoute(
        await Future.any<SourceNetworkRoute>([
          // 不传目标：WebView 自己跟随系统代理，不能把系统代理固化成启动参数。
          _resolver.resolve(directConnection: directConnection),
          request.cancelled.then<SourceNetworkRoute>(
            (_) => throw const VideoSourceCancelledException(),
          ),
        ]),
      );
      request.throwIfNotCurrent(_activeRequest);
      lease = await _acquireLease(route, cancelled: request.cancelled);
      request.throwIfNotCurrent(_activeRequest);
      if (_webview == null ||
          _route != route ||
          _userAgent != userAgent ||
          _legacyParser != useLegacyParser) {
        await _disposeWebview();
        request.throwIfNotCurrent(_activeRequest);
        final view = _factory();
        _webview = view;
        _logSubscription = view.onLog.listen((log) {
          if (!_logController.isClosed) _logController.add(log);
        });
        try {
          await view
              .init(userAgent: userAgent, route: route)
              .timeout(const Duration(seconds: 10));
        } catch (_) {
          await _disposeWebview();
          rethrow;
        }
        _route = route;
        _userAgent = userAgent;
        _legacyParser = useLegacyParser;
      }
      request.throwIfNotCurrent(_activeRequest);
      final view = _webview!;
      final parsed = Completer<VideoParserEvent>();
      parserSubscription = view.onVideoURLParser.listen(
        (event) {
          if (!parsed.isCompleted) parsed.complete(event);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!parsed.isCompleted) parsed.completeError(error, stackTrace);
        },
      );
      // 先订阅再导航，快速命中的媒体事件不能丢失。
      didStartLoad = true;
      final navigation =
          Future.sync(
            () => view.loadUrl(episodeUrl, useLegacyParser, offset: offset),
          ).whenComplete(() {
            navigationSettled = true;
          });
      final loadedAndParsed = Future.wait<Object?>([
        navigation.then<Object?>((_) => null),
        parsed.future,
      ], eagerError: true).then((values) => values.last as VideoParserEvent);
      final event =
          await Future.any<VideoParserEvent>([
            loadedAndParsed,
            request.cancelled.then<VideoParserEvent>(
              (_) => throw const VideoSourceCancelledException(),
            ),
          ]).timeout(
            timeout,
            onTimeout: () {
              request.throwIfNotCurrent(_activeRequest);
              throw VideoSourceTimeoutException(timeout);
            },
          );
      request.throwIfNotCurrent(_activeRequest);
      return VideoSource(
        url: event.url,
        offset: event.offset,
        type: VideoSourceType.online,
        format: event.format,
      );
    } on SourceProxyLeaseCancelled {
      throw const VideoSourceCancelledException();
    } catch (_) {
      request.throwIfNotCurrent(_activeRequest);
      rethrow;
    } finally {
      try {
        await parserSubscription?.cancel();
        if (didStartLoad && !navigationSettled) {
          await _disposeWebview();
        } else if (didStartLoad) {
          try {
            await _webview?.unloadPage();
          } catch (error) {
            KazumiLogger().w('WebView: 页面卸载失败，销毁实例 $error');
            await _disposeWebview();
          }
        }
      } finally {
        try {
          await lease?.release();
        } finally {
          if (identical(_activeRequest, request)) _activeRequest = null;
        }
      }
    }
  }

  Future<void> _disposeWebview() async {
    await _logSubscription?.cancel();
    _logSubscription = null;
    final view = _webview;
    _webview = null;
    _route = null;
    await view?.dispose();
  }

  @override
  void cancel() => _activeRequest?.cancel();

  @override
  Future<void> dispose() async {
    final previous = _resolveTail;
    _resolveTail = null;
    cancel();
    await previous;
    _activeRequest = null;
    await _disposeWebview();
    await _logController.close();
  }
}

class _ResolveRequest {
  final _cancelled = Completer<void>();
  Future<void> get cancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void throwIfNotCurrent(_ResolveRequest? current) {
    if (_cancelled.isCompleted || !identical(current, this)) {
      throw const VideoSourceCancelledException();
    }
  }
}
