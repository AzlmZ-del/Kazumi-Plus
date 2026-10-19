import 'dart:io';

import 'package:flutter/material.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/http_headers.dart';
import 'package:webview_windows/webview_windows.dart' as windows;

/// 打开 [InternalBrowserPage] 时通过路由传入的参数。
class InternalBrowserArgs {
  const InternalBrowserArgs({
    required this.url,
    required this.title,
  });

  final String url;
  final String title;
}

/// 内置浏览器页面：在应用内直接浏览网页（如 bangumi.tv 条目页）。
///
/// Windows 使用 webview_windows 的可见 WebView，Android/iOS/macOS 使用
/// flutter_inappwebview 的可见 WebView。Linux 的 desktop_webview_window
/// 不提供可嵌入的 widget，退回到打开独立原生窗口。
class InternalBrowserPage extends StatefulWidget {
  const InternalBrowserPage({
    super.key,
    required this.url,
    required this.title,
  });

  final String url;
  final String title;

  @override
  State<InternalBrowserPage> createState() => _InternalBrowserPageState();
}

class _InternalBrowserPageState extends State<InternalBrowserPage> {
  @override
  void initState() {
    super.initState();
    if (Platform.isLinux) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openLinuxWindow();
      });
    }
  }

  Future<void> _openLinuxWindow() async {
    try {
      final controller = await WebviewWindow.create(
        configuration: const CreateConfiguration(),
      );
      controller.launch(widget.url);
    } catch (error) {
      KazumiLogger().w('InternalBrowser: linux window failed', error: error);
      KazumiDialog.showToast(message: '内置浏览器启动失败');
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isLinux) {
      return Scaffold(
        appBar: SysAppBar(title: Text(widget.title, maxLines: 1)),
        body: const SafeArea(
          top: false,
          child: GeneralErrorWidget(
            title: '正在打开浏览器窗口',
            errMsg: 'Linux 平台将在独立窗口中打开该页面。',
          ),
        ),
      );
    }
    if (Platform.isWindows) {
      return _WindowsBrowserPage(url: widget.url, title: widget.title);
    }
    return _InAppBrowserPage(url: widget.url, title: widget.title);
  }
}

class _BrowserScaffold extends StatelessWidget {
  const _BrowserScaffold({
    required this.title,
    required this.progress,
    required this.child,
  });

  final String title;
  final int? progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final showBar = progress != null && progress! < 100;
    return Scaffold(
      appBar: SysAppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (showBar)
              LinearProgressIndicator(
                value: progress! / 100,
                minHeight: 2,
              ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _WindowsBrowserPage extends StatefulWidget {
  const _WindowsBrowserPage({required this.url, required this.title});

  final String url;
  final String title;

  @override
  State<_WindowsBrowserPage> createState() => _WindowsBrowserPageState();
}

class _WindowsBrowserPageState extends State<_WindowsBrowserPage> {
  final windows.WebviewController _controller = windows.WebviewController();
  bool _ready = false;
  bool _failed = false;
  int? _progress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _init();
    });
  }

  Future<void> _init() async {
    try {
      await windows.WebviewController.initializeEnvironment();
      await _controller.initialize();
      _controller.setPopupWindowPolicy(
          windows.WebviewPopupWindowPolicy.deny);
      _controller.loadingState.listen((state) {
        if (!mounted) return;
        setState(() {
          if (state == windows.LoadingState.navigationCompleted) {
            _progress = 100;
          } else if (state == windows.LoadingState.loading) {
            _progress ??= 10;
          }
        });
      });
      await _controller.loadUrl(widget.url);
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (error) {
      KazumiLogger().w('InternalBrowser: windows init failed', error: error);
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _BrowserScaffold(
      title: widget.title,
      progress: _progress,
      child: _failed
          ? GeneralErrorWidget(
              title: '内置浏览器启动失败',
              errMsg: 'WebView 组件未能初始化，请使用外部浏览器打开。',
            )
          : !_ready
              ? const Center(child: CircularProgressIndicator())
              : windows.Webview(_controller),
    );
  }
}

class _InAppBrowserPage extends StatefulWidget {
  const _InAppBrowserPage({required this.url, required this.title});

  final String url;
  final String title;

  @override
  State<_InAppBrowserPage> createState() => _InAppBrowserPageState();
}

class _InAppBrowserPageState extends State<_InAppBrowserPage> {
  int? _progress;

  @override
  Widget build(BuildContext context) {
    return _BrowserScaffold(
      title: widget.title,
      progress: _progress,
      child: PlatformInAppWebViewWidget(
        PlatformInAppWebViewWidgetCreationParams(
          initialUrlRequest: URLRequest(url: WebUri(widget.url)),
          initialSettings: InAppWebViewSettings(
            userAgent: getRandomUA(),
            mediaPlaybackRequiresUserGesture: true,
            cacheEnabled: true,
            transparentBackground: false,
            safeBrowsingEnabled: false,
            upgradeKnownHostsToHTTPS: false,
          ),
          onProgressChanged: (controller, progress) {
            if (!mounted) return;
            setState(() => _progress = progress);
          },
        ),
      ).build(context),
    );
  }
}
