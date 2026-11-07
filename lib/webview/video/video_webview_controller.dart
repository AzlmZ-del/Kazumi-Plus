import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kazumi/webview/video/impl/video_webview_android_impl.dart';
import 'package:kazumi/webview/video/impl/video_webview_impl.dart';
import 'package:kazumi/webview/video/impl/video_webview_windows_impl.dart';
import 'package:kazumi/webview/video/impl/video_webview_linux_impl.dart';
import 'package:kazumi/webview/video/impl/video_webview_apple_impl.dart';
import 'package:kazumi/services/platform/webview_feature_service.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';

typedef VideoParserEvent = ({
  String url,
  int offset,
  VideoSourceFormat format,
});

abstract class VideoWebviewController<T> {
  // WebView 控制器。
  T? webviewController;

  // 重试次数。
  int count = 0;
  // 上次观看位置。
  int offset = 0;
  bool isIframeLoaded = false;
  bool isVideoSourceLoaded = false;

  /// 初始化 WebView。
  ///
  /// [userAgent] 规则自带的 UA。非空时 WebView 必须用它，让页面内拿到的
  /// 资源与后续媒体请求保持同一个 UA，避免站点按 UA 做防盗链时对不上。
  /// 为空时各平台自行回落到浏览器 UA 池。
  Future<void> init({String userAgent = ''});

  final StreamController<bool> initEventController =
      StreamController<bool>.broadcast();

  // webview 初始化完成时通知的流。
  Stream<bool> get onInitialized => initEventController.stream;

  final StreamController<String> logEventController =
      StreamController<String>.broadcast();

  // 订阅 webview 日志的流。
  Stream<String> get onLog => logEventController.stream;

  final StreamController<bool> videoLoadingEventController =
      StreamController<bool>.broadcast();

  // 视频源地址解析完成时通知的流，带上播放起点与解析器确认过的格式信息。
  final StreamController<VideoParserEvent> _videoParserEventController =
      StreamController<VideoParserEvent>.broadcast();

  Stream<VideoParserEvent> get onVideoURLParser =>
      _videoParserEventController.stream;

  @protected
  void notifyVideoSourceResolved(
    String url, {
    VideoSourceFormat format = VideoSourceFormat.auto,
  }) {
    _videoParserEventController.add((
      url: url,
      offset: offset,
      format: format,
    ));
  }

  void disposeEventControllers() {
    if (!initEventController.isClosed) {
      initEventController.close();
    }
    if (!logEventController.isClosed) {
      logEventController.close();
    }
    if (!videoLoadingEventController.isClosed) {
      videoLoadingEventController.close();
    }
    if (!_videoParserEventController.isClosed) {
      _videoParserEventController.close();
    }
  }

  /// 让 WebView 加载指定 URL。
  Future<void> loadUrl(String url, bool useLegacyParser, {int offset = 0});

  /// 让 WebView 卸载当前页面。
  Future<void> unloadPage();

  /// 释放 WebView 资源。
  Future<void> dispose();
}

class VideoWebviewControllerFactory {
  static VideoWebviewController getController() {
    if (Platform.isWindows) {
      return VideoWebviewWindowsImpl();
    }
    if (Platform.isLinux) {
      return VideoWebviewLinuxImpl();
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return VideoWebviewAppleImpl();
    }
    if (Platform.isAndroid &&
        WebViewFeatureService.isDocumentStartScriptSupported) {
      return VideoWebviewAndroidImpl();
    }
    return VideoWebviewImpl();
  }
}
