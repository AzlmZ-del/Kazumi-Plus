import 'dart:async';
import 'package:webview_windows/webview_windows.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/utils/http_headers.dart';

class VideoWebviewWindowsImpl
    extends VideoWebviewController<WebviewController> {
  final List<StreamSubscription> subscriptions = [];

  HeadlessWebview? headlessWebview;

  @override
  Future<void> init({String userAgent = ''}) async {
    await _setupProxy();
    headlessWebview ??= HeadlessWebview();
    await headlessWebview!.run();
    await headlessWebview!.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
    await _applyUserAgent(userAgent);
    initEventController.add(true);
  }

  /// WebView2 只能在实例启动后设置 UA，故放在 [HeadlessWebview.run] 之后。
  Future<void> _applyUserAgent(String ruleUserAgent) async {
    final resolved = resolveWebviewUserAgent(ruleUserAgent);
    try {
      await headlessWebview!.setUserAgent(resolved);
      KazumiLogger().i('WebView: UA 已设置 $resolved');
    } catch (e) {
      KazumiLogger().w('WebView: UA 设置失败 $e');
    }
  }

  Future<void> _setupProxy() async {
    final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (!proxyEnable) {
      return;
    }

    final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
    final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
    if (formattedProxy == null) {
      return;
    }

    try {
      await WebviewController.initializeEnvironment(
        additionalArguments: '--proxy-server=$formattedProxy',
      );
      KazumiLogger().i('WebView: 代理设置成功 $formattedProxy');
    } catch (e) {
      KazumiLogger().e('WebView: 设置代理失败 $e');
    }
  }

  @override
  Future<void> loadUrl(String url, bool useLegacyParser,
      {int offset = 0}) async {
    await unloadPage();
    count = 0;
    this.offset = offset;
    isIframeLoaded = false;
    isVideoSourceLoaded = false;
    videoLoadingEventController.add(true);
    subscriptions.add(headlessWebview!.onM3USourceLoaded.listen((data) {
      if (headlessWebview == null) return;
      String url = data['url'] ?? '';
      if (url.isEmpty) {
        return;
      }
      unloadPage();
      isIframeLoaded = true;
      isVideoSourceLoaded = true;
      videoLoadingEventController.add(false);
      logEventController.add('Loading m3u8 source: $url');
      notifyVideoSourceResolved(
        url,
        format: VideoSourceFormat.hls,
      );
    }));
    subscriptions.add(headlessWebview!.onVideoSourceLoaded.listen((data) {
      if (headlessWebview == null) return;
      String url = data['url'] ?? '';
      if (url.isEmpty) {
        return;
      }
      unloadPage();
      isIframeLoaded = true;
      isVideoSourceLoaded = true;
      videoLoadingEventController.add(false);
      logEventController.add('Loading video source: $url');
      notifyVideoSourceResolved(url);
    }));
    await headlessWebview!.loadUrl(url);
  }

  @override
  Future<void> unloadPage() async {
    for (final s in subscriptions) {
      try {
        s.cancel();
      } catch (_) {}
    }
    subscriptions.clear();
    await redirect2Blank();
  }

  @override
  Future<void> dispose() async {
    for (final s in subscriptions) {
      try {
        s.cancel();
      } catch (_) {}
    }
    subscriptions.clear();
    await headlessWebview?.dispose();
    headlessWebview = null;
    disposeEventControllers();
  }

  // webview_windows 没有卸载当前页面的方法。
  // 用 loadUrl 会新开一个标签页，导致内存泄漏。
  // 直接销毁 webview 控制器又要在切集时重新初始化，代价太大。
  // 所以这里改成跳到一个空白页来替代卸载。
  Future<void> redirect2Blank() async {
    if (headlessWebview == null) return;
    try {
      await headlessWebview!.executeScript('''
        window.location.href = 'about:blank';
      ''');
    } catch (e) {
      KazumiLogger().d('WebView: redirect2Blank skipped (likely disposed): $e');
    }
  }
}
