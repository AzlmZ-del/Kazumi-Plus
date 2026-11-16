import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/source_proxy_lease.dart';
import 'package:kazumi/services/plugin/captcha_verification_service.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';
import 'package:kazumi/services/video_source/webview_video_source_service.dart';
import 'package:kazumi/webview/captcha/captcha_webview_controller.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';

class _VideoView extends VideoWebviewController<Object> {
  _VideoView(
    this.events, {
    this.emit = true,
    this.failInit = false,
    this.failUnload = false,
    this.navigationGate,
  });
  final List<String> events;
  final Completer<void>? navigationGate;
  bool disposed = false;
  final bool emit;
  final bool failInit;
  final bool failUnload;
  final loaded = Completer<void>();

  @override
  Future<void> init({
    String userAgent = '',
    SourceNetworkRoute route = const SourceNetworkRoute.system(),
  }) async {
    events.add('init:${route.mode.name}:$userAgent');
    if (failInit) throw StateError('init failed');
    initEventController.add(true);
  }

  @override
  Future<void> loadUrl(
    String url,
    bool useLegacyParser, {
    int offset = 0,
  }) async {
    events.add('load');
    this.offset = offset;
    if (!loaded.isCompleted) loaded.complete();
    if (navigationGate != null) {
      await navigationGate!.future;
      if (disposed) return;
      events.add('effective-load');
    }
    if (emit) {
      notifyVideoSourceResolved(
        'https://media.example/video.m3u8',
        format: VideoSourceFormat.hls,
      );
    }
  }

  @override
  Future<void> unloadPage() async {
    events.add('unload');
    if (failUnload) throw StateError('unload failed');
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    events.add('dispose');
    disposeEventControllers();
  }
}

class _CaptchaView extends CaptchaWebviewController<Object> {
  _CaptchaView(this.events, {this.verify = false, this.failInit = false});
  final List<String> events;
  final bool verify;
  final bool failInit;
  final loaded = Completer<void>();
  int initializations = 0;

  @override
  Future<void> init({
    String userAgent = '',
    SourceNetworkRoute route = const SourceNetworkRoute.system(),
  }) async {
    initializations++;
    events.add('captcha:init:${route.mode.name}:$userAgent');
    if (failInit) throw StateError('captcha init failed');
    initEventController.add(true);
  }

  @override
  Future<void> loadPage(
    String url,
    String captchaXpath, {
    String? inputXpath,
  }) async {
    events.add('captcha:load');
    if (!loaded.isCompleted) loaded.complete();
  }

  @override
  Future<void> loadPageForButtonClick(String url, String buttonXpath) async {
    await loadPage(url, buttonXpath);
    if (verify) captchaDisappearedController.add(null);
  }

  @override
  Future<void> loadPageForCustomScript(String url, String script) =>
      loadPageForButtonClick(url, script);

  @override
  Future<void> submitCaptchaInteract(
    String code,
    String inputXpath,
    String buttonXpath,
  ) async {}

  @override
  Future<String> getCookieString(String pageUrl) async => '';

  @override
  Future<String> getPageHtml() async => '<html>verified</html>';

  @override
  Future<String> getUserAgent() async => 'rule-agent';

  @override
  Future<void> unloadPage() async {
    events.add('captcha:unload');
  }

  @override
  Future<void> dispose() async {
    events.add('captcha:dispose');
    await captchaImageFoundController.close();
    await captchaDisappearedController.close();
    await initEventController.close();
    await logEventController.close();
  }
}

SourceNetworkResolver _resolver() => SourceNetworkResolver(
  isAndroid: false,
  isVpnActive: () async => false,
  startGateway: () async => throw StateError('unexpected native gateway'),
  defaultRoute: (target) {
    expect(
      target,
      isNull,
      reason: 'WebView must retain its own system proxy behavior',
    );
    return const SourceNetworkRoute.system();
  },
);

SourceProxyLeaseManager _manager(List<String> events) =>
    SourceProxyLeaseManager(
      apply: (route) async {
        events.add('apply:${route.mode.name}');
      },
      restore: () async {
        events.add('restore');
      },
    );

void main() {
  test(
    'video subscribes before navigation and releases after unloading',
    () async {
      final events = <String>[];
      final manager = _manager(events);
      final view = _VideoView(events);
      final service = WebViewVideoSourceService(
        resolver: _resolver(),
        webviewFactory: () => view,
        acquireLease: manager.acquire,
      );
      final source = await service.resolve(
        'https://source.example/episode',
        useLegacyParser: false,
        offset: 12,
        userAgent: 'rule-agent',
      );
      expect(source.url, 'https://media.example/video.m3u8');
      expect(source.offset, 12);
      expect(source.format, VideoSourceFormat.hls);
      expect(events, [
        'apply:system',
        'init:system:rule-agent',
        'load',
        'unload',
        'restore',
      ]);
      await service.dispose();
    },
  );

  test('video timeout unloads the page and releases its lease', () async {
    final events = <String>[];
    final manager = _manager(events);
    final service = WebViewVideoSourceService(
      resolver: _resolver(),
      webviewFactory: () => _VideoView(events, emit: false),
      acquireLease: manager.acquire,
    );
    await expectLater(
      service.resolve(
        'https://source.example/episode',
        useLegacyParser: false,
        timeout: const Duration(milliseconds: 5),
      ),
      throwsA(isA<VideoSourceTimeoutException>()),
    );
    expect(events.sublist(events.length - 2), ['unload', 'restore']);
    await service.dispose();
  });

  test(
    'video cancellation while waiting for a lease never creates a page',
    () async {
      final events = <String>[];
      final manager = _manager(events);
      final active = await manager.acquire(const SourceNetworkRoute.system());
      var created = 0;
      final service = WebViewVideoSourceService(
        resolver: _resolver(),
        webviewFactory: () {
          created++;
          return _VideoView(events);
        },
        acquireLease: manager.acquire,
      );
      final resolving = service.resolve(
        'https://source.example/episode',
        useLegacyParser: false,
        directConnection: true,
      );
      final expectation = expectLater(
        resolving,
        throwsA(isA<VideoSourceCancelledException>()),
      );
      await Future<void>.delayed(Duration.zero);
      service.cancel();
      await expectation;
      expect(created, 0);
      expect(events, ['apply:system']);
      await active.release();
      await service.dispose();
    },
  );

  test('video cancellation after navigation restores before dispose', () async {
    final events = <String>[];
    final manager = _manager(events);
    final view = _VideoView(events, emit: false);
    final service = WebViewVideoSourceService(
      resolver: _resolver(),
      webviewFactory: () => view,
      acquireLease: manager.acquire,
    );
    final resolving = service.resolve(
      'https://source.example/episode',
      useLegacyParser: false,
    );
    final expectation = expectLater(
      resolving,
      throwsA(isA<VideoSourceCancelledException>()),
    );
    await view.loaded.future;
    service.cancel();
    await expectation;
    expect(events.sublist(events.length - 2), ['unload', 'restore']);
    await service.dispose();
  });

  test(
    'pending navigation is destroyed before its proxy lease is released',
    () async {
      final events = <String>[];
      final manager = _manager(events);
      final gate = Completer<void>();
      final view = _VideoView(events, navigationGate: gate);
      final service = WebViewVideoSourceService(
        resolver: _resolver(),
        webviewFactory: () => view,
        acquireLease: manager.acquire,
      );
      final resolving = service.resolve(
        'https://source.example/episode',
        useLegacyParser: false,
      );
      final expectation = expectLater(
        resolving,
        throwsA(isA<VideoSourceCancelledException>()),
      );
      await view.loaded.future;
      service.cancel();
      await expectation;
      expect(view.disposed, isTrue);
      expect(events.sublist(events.length - 2), ['dispose', 'restore']);
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(events, isNot(contains('effective-load')));
      await service.dispose();
    },
  );

  test(
    'video init failure destroys the incomplete page before restoring',
    () async {
      final events = <String>[];
      final manager = _manager(events);
      final service = WebViewVideoSourceService(
        resolver: _resolver(),
        webviewFactory: () => _VideoView(events, failInit: true),
        acquireLease: manager.acquire,
      );
      await expectLater(
        service.resolve(
          'https://source.example/episode',
          useLegacyParser: false,
        ),
        throwsStateError,
      );
      expect(events.sublist(events.length - 2), ['dispose', 'restore']);
      await service.dispose();
    },
  );

  test(
    'failed unload destroys the page before releasing global proxy state',
    () async {
      final events = <String>[];
      final manager = _manager(events);
      final service = WebViewVideoSourceService(
        resolver: _resolver(),
        webviewFactory: () => _VideoView(events, failUnload: true),
        acquireLease: manager.acquire,
      );
      await service.resolve(
        'https://source.example/episode',
        useLegacyParser: false,
      );
      expect(events.sublist(events.length - 3), [
        'unload',
        'dispose',
        'restore',
      ]);
      await service.dispose();
    },
  );

  test(
    'route, user-agent and parser changes rebuild the cached page',
    () async {
      final events = <String>[];
      final manager = _manager(events);
      var created = 0;
      final service = WebViewVideoSourceService(
        resolver: _resolver(),
        webviewFactory: () {
          created++;
          return _VideoView(events);
        },
        acquireLease: manager.acquire,
      );
      Future<void> resolve({
        bool direct = false,
        String ua = 'a',
        bool legacy = false,
      }) async {
        await service.resolve(
          'https://source.example/episode',
          useLegacyParser: legacy,
          directConnection: direct,
          userAgent: ua,
        );
      }

      await resolve();
      await resolve();
      expect(created, 1);
      await resolve(direct: true);
      await resolve(direct: true, ua: 'b');
      await resolve(direct: true, ua: 'b', legacy: true);
      expect(created, 4);
      await service.dispose();
      await expectLater(
        resolve(),
        throwsA(isA<VideoSourceCancelledException>()),
      );
    },
  );

  test(
    'captcha initialization shares one lease and disposes before restoring',
    () async {
      final events = <String>[];
      final manager = _manager(events);
      final view = _CaptchaView(events);
      final service = CaptchaVerificationService(
        resolver: _resolver(),
        webviewFactory: () => view,
        acquireLease: manager.acquire,
      );
      service.applyRuleUserAgent('rule-agent');
      service.applyRuleNetwork(true);
      await Future.wait([
        service.loadForCaptcha('https://source.example/search', '//img'),
        service.loadForCaptcha('https://source.example/search', '//img'),
      ]);
      expect(view.initializations, 1);
      expect(events.where((event) => event == 'apply:direct'), hasLength(1));
      expect(events, contains('captcha:init:direct:rule-agent'));
      expect(events, isNot(contains('restore')));
      await service.dispose();
      expect(events.sublist(events.length - 3), [
        'captcha:unload',
        'captcha:dispose',
        'restore',
      ]);
      await service.dispose();
      expect(events.where((event) => event == 'restore'), hasLength(1));
    },
  );

  test(
    'captcha cancelled while queued cannot navigate or acquire a holder',
    () async {
      final events = <String>[];
      final manager = _manager(events);
      final active = await manager.acquire(const SourceNetworkRoute.system());
      var created = 0;
      final service = CaptchaVerificationService(
        resolver: _resolver(),
        webviewFactory: () {
          created++;
          return _CaptchaView(events);
        },
        acquireLease: manager.acquire,
      );
      service.applyRuleNetwork(true);
      final loading = service.loadForCaptcha(
        'https://source.example/search',
        '//img',
      );
      final expectation = expectLater(
        loading,
        throwsA(isA<SourceProxyLeaseCancelled>()),
      );
      await Future<void>.delayed(Duration.zero);
      await service.cancelAndSave('example');
      await expectation;
      await service.dispose();
      expect(created, 0);
      expect(events, ['apply:system']);
      await active.release();
    },
  );

  test(
    'captcha init failure releases its lease without an unhandled stream error',
    () async {
      final events = <String>[];
      final manager = _manager(events);
      final service = CaptchaVerificationService(
        resolver: _resolver(),
        webviewFactory: () => _CaptchaView(events, failInit: true),
        acquireLease: manager.acquire,
      );
      await expectLater(
        service.loadForCaptcha('https://source.example/search', '//img'),
        throwsStateError,
      );
      expect(events.sublist(events.length - 3), [
        'captcha:unload',
        'captcha:dispose',
        'restore',
      ]);
      await service.dispose();
    },
  );

  test(
    'captcha success keeps its lease until cookie work and disposal finish',
    () async {
      final events = <String>[];
      final manager = _manager(events);
      final view = _CaptchaView(events, verify: true);
      final service = CaptchaVerificationService(
        resolver: _resolver(),
        webviewFactory: () => view,
        acquireLease: manager.acquire,
      );
      service.applyRuleNetwork(true);
      final verified = Completer<String>();
      await service.loadForButtonClick(
        url: 'https://source.example/search',
        buttonXpath: '//button',
        pluginName: 'example',
        onVerified: verified.complete,
      );
      expect(await verified.future, '<html>verified</html>');
      expect(events, isNot(contains('restore')));
      var acquired = false;
      final next = manager.acquire(const SourceNetworkRoute.system()).then((
        lease,
      ) {
        acquired = true;
        return lease;
      });
      await Future<void>.delayed(Duration.zero);
      expect(acquired, isFalse);
      await service.dispose();
      final lease = await next;
      expect(
        events.indexOf('captcha:dispose'),
        lessThan(events.indexOf('restore')),
      );
      await lease.release();
    },
  );
}
