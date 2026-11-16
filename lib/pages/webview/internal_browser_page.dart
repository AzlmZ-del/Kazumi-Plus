import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/network/source_network_service.dart';
import 'package:kazumi/services/network/source_proxy_lease.dart';
import 'package:kazumi/services/network/source_webview_network.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:webview_windows/webview_windows.dart' as windows;

/// 打开 [InternalBrowserPage] 时通过路由传入的参数。
class InternalBrowserArgs {
  const InternalBrowserArgs({
    required this.url,
    required this.title,
    this.userAgent = '',
    this.directConnection = false,
  });

  final String url;
  final String title;

  /// 站点（规则）配置的 User-Agent；为空时退回手机 UA。
  final String userAgent;

  /// 规则是否声明直连；内置浏览尽量跟随，无法强制时提示后照常打开。
  final bool directConnection;
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
    this.userAgent = '',
    this.directConnection = false,
  });

  final String url;
  final String title;

  /// 站点（规则）配置的 User-Agent；为空时退回手机 UA。
  final String userAgent;

  /// 规则是否声明直连；内置浏览尽量跟随，无法强制时提示后照常打开。
  final bool directConnection;

  @override
  State<InternalBrowserPage> createState() => _InternalBrowserPageState();
}

class _InternalBrowserPageState extends State<InternalBrowserPage> {
  SourceProxyLease? _lease;
  bool _networkReady = false;
  String? _notice;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isLinux) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openLinuxWindow();
      });
      return;
    }
    _prepareNetwork();
  }

  /// 尽量按规则设定准备出口；兑现不了只记提示，不阻断浏览。
  Future<void> _prepareNetwork() async {
    try {
      final route = await SourceNetworkService.resolver.resolve(
        directConnection: widget.directConnection,
      );
      if (_disposed) return;
      final result = await SourceWebviewNetwork.acquireForBrowser(route);
      if (_disposed) {
        await result.lease.release();
        return;
      }
      setState(() {
        _lease = result.lease;
        _notice = result.notice;
        _networkReady = true;
      });
    } catch (error) {
      KazumiLogger().w('InternalBrowser: network prepare failed', error: error);
      if (!mounted) return;
      setState(() {
        _notice = '直连准备失败，已按系统网络打开';
        _networkReady = true;
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final lease = _lease;
    _lease = null;
    if (lease != null) unawaited(lease.release());
    super.dispose();
  }

  Future<void> _openLinuxWindow() async {
    try {
      // Linux 窗口创建后无法再改出口，必须在创建前定好；
      // 直连无法兑现时 adaptRoute 退回该平台原本的加载方式。
      final requested = await SourceNetworkService.resolver.resolve(
        directConnection: widget.directConnection,
      );
      final route = SourceWebviewNetwork.adaptRoute(requested);
      final controller = await WebviewWindow.create(
        configuration: CreateConfiguration(proxy: _proxyOf(route)),
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

  /// Linux 的 WebView 只接受 http 代理地址，没有强制 DIRECT 的通道。
  ProxyConfiguration? _proxyOf(SourceNetworkRoute route) {
    final url = route.proxyUrl;
    if (url == null) return null;
    final parsed = ProxyUtils.parseProxyUrl(url);
    if (parsed == null) return null;
    return ProxyConfiguration(host: parsed.$1, port: parsed.$2);
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
    if (!_networkReady) {
      return _BrowserScaffold(
        title: widget.title,
        progress: null,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    final notice = _notice;
    if (notice == null) {
      return _browserBody();
    }
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    notice,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: _browserBody()),
      ],
    );
  }

  Widget _browserBody() {
    if (Platform.isWindows) {
      return _WindowsBrowserPage(
        url: widget.url,
        title: widget.title,
        userAgent: widget.userAgent,
        directConnection: widget.directConnection,
      );
    }
    return _InAppBrowserPage(
      url: widget.url,
      title: widget.title,
      userAgent: widget.userAgent,
    );
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
              LinearProgressIndicator(value: progress! / 100, minHeight: 2),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _WindowsBrowserPage extends StatefulWidget {
  const _WindowsBrowserPage({
    required this.url,
    required this.title,
    this.userAgent = '',
    this.directConnection = false,
  });

  final String url;
  final String title;
  final String userAgent;
  final bool directConnection;

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
      // WebView2 的 environment 是一次性的，代理参数只能在这里给。
      await windows.WebviewController.initializeEnvironment(
        additionalArguments: widget.directConnection
            ? '--no-proxy-server'
            : null,
      );
      await _controller.initialize();
      _controller.setPopupWindowPolicy(windows.WebviewPopupWindowPolicy.deny);
      // 源的 UA 必须在加载前设置，否则首屏仍用默认 UA。
      final userAgent = widget.userAgent.trim();
      if (userAgent.isNotEmpty) {
        try {
          await _controller.setUserAgent(userAgent);
        } catch (error) {
          KazumiLogger().w('InternalBrowser: set UA failed', error: error);
        }
      }
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
  const _InAppBrowserPage({
    required this.url,
    required this.title,
    this.userAgent = '',
  });

  final String url;
  final String title;
  final String userAgent;

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
            userAgent: widget.userAgent.trim().isEmpty
                ? mobileUserAgent
                : widget.userAgent.trim(),
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
