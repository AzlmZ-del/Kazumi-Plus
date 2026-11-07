import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/proxy_manager.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:win32/win32.dart';

/// Windows 系统代理配置的快照。
class SystemProxyState {
  const SystemProxyState({
    this.httpProxy,
    this.httpsProxy,
    this.bypassPatterns = const [],
    this.bypassLocal = false,
  });

  final (String, int)? httpProxy;
  final (String, int)? httpsProxy;
  final List<String> bypassPatterns;
  final bool bypassLocal;

  bool get hasProxy => httpProxy != null || httpsProxy != null;

  bool sameAs(SystemProxyState other) {
    if (httpProxy != other.httpProxy || httpsProxy != other.httpsProxy) {
      return false;
    }
    if (bypassLocal != other.bypassLocal) return false;
    if (bypassPatterns.length != other.bypassPatterns.length) return false;
    for (var i = 0; i < bypassPatterns.length; i++) {
      if (bypassPatterns[i] != other.bypassPatterns[i]) return false;
    }
    return true;
  }
}

/// 在 Windows 上跟随 WinINET 系统代理，行为对齐 Chrome。
///
/// 注册表快照只存在内存里。变更通知通过异步的 `RegNotifyChangeKeyValue`
/// 事件送达，该事件在系统线程池上等待，因此任何 Dart isolate 都不会在原生代码里
/// 阻塞（isolate 一阻塞，hot reload 就卡住）。
///
/// 应用内手动代理在结构上优先：只有在没配手动代理时，
/// 调用点才会装载 [findProxy]。
class SystemProxyService {
  SystemProxyService._();

  static const _regPath =
      r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  static SystemProxyState _state = const SystemProxyState();
  static bool _watcherStarted = false;
  static Timer? _debounce;

  /// 仅 Windows；要在 `runApp` 之前调用，
  /// 否则最初的几个请求看到的还是旧状态。
  static void init() {
    if (!Platform.isWindows) return;
    refresh();
    _startWatcher();
  }

  /// 重新读注册表。生效配置有变化时返回 true。
  static bool refresh() {
    if (!Platform.isWindows) return false;
    SystemProxyState newState;
    try {
      newState = _readFromRegistry();
    } catch (e) {
      KazumiLogger().w('Proxy: 读取系统代理配置失败 $e');
      newState = const SystemProxyState();
    }
    if (newState.sameAs(_state)) return false;
    _state = newState;
    final proxy = newState.httpProxy ?? newState.httpsProxy;
    KazumiLogger().i(proxy == null
        ? 'Proxy: 系统代理已移除，回到直连'
        : 'Proxy: 检测到系统代理 ${proxy.$1}:${proxy.$2}');
    return true;
  }

  static bool get isActive => Platform.isWindows && _state.hasProxy;

  /// 取 [scheme]（'http' 或 'https'）对应的代理，
  /// 供用不了 [findProxy] 的调用方使用（例如 mpv）。
  static (String, int)? proxyFor(String scheme) {
    if (!isActive) return null;
    return scheme == 'https' ? _state.httpsProxy : _state.httpProxy;
  }

  /// 给 `HttpClient.findProxy` 用的 PAC 风格回调，永不抛异常。
  static String findProxy(Uri url) {
    try {
      if (!isActive) return 'DIRECT';
      final state = _state;
      if (_shouldBypass(url, state)) return 'DIRECT';
      final proxy =
          url.scheme == 'https' ? state.httpsProxy : state.httpProxy;
      if (proxy == null) return 'DIRECT';
      return 'PROXY ${proxy.$1}:${proxy.$2}';
    } catch (_) {
      return 'DIRECT';
    }
  }

  /// 解析 `ProxyServer`：要么是一个 `host:port` 同时给两种协议，
  /// 要么是 `http=h:p;https=h:p` 这样的分协议列表。
  /// `http` 与 `https` 互相兜底；`ftp`/`socks` 是 `HttpClient` 用不了的。
  static ((String, int)?, (String, int)?) _parseProxyServer(String raw) {
    raw = raw.trim();
    if (raw.isEmpty) return (null, null);

    if (!raw.contains('=')) {
      final parsed = _parseHostPort(raw);
      return (parsed, parsed);
    }

    (String, int)? http;
    (String, int)? https;
    for (final entry in raw.split(';')) {
      final idx = entry.indexOf('=');
      if (idx <= 0) continue;
      final scheme = entry.substring(0, idx).trim().toLowerCase();
      final parsed = _parseHostPort(entry.substring(idx + 1));
      if (parsed == null) continue;
      if (scheme == 'http') http = parsed;
      if (scheme == 'https') https = parsed;
    }
    return (http ?? https, https ?? http);
  }

  /// 解析 `host:port`，兼容 `scheme://` 前缀与 `[IPv6]:port` 写法。
  static (String, int)? _parseHostPort(String value) {
    value = value.trim();
    if (value.isEmpty) return null;

    final schemeIdx = value.indexOf('://');
    if (schemeIdx > 0) {
      value = value.substring(schemeIdx + 3);
    }

    // IPv6 字面量本身带冒号，所以端口取最后一个冒号之后的部分。
    final colon = value.lastIndexOf(':');
    if (colon <= 0 || colon == value.length - 1) return null;

    var host = value.substring(0, colon);
    final port = int.tryParse(value.substring(colon + 1));
    if (port == null || port < 1 || port > 65535) return null;

    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (host.isEmpty) return null;
    return (host, port);
  }

  static (List<String>, bool) _parseBypassList(String raw) {
    final patterns = <String>[];
    var bypassLocal = false;
    for (final part in raw.split(RegExp(r'[;,]'))) {
      var entry = part.trim().toLowerCase();
      if (entry.isEmpty) continue;
      if (entry == '<local>') {
        bypassLocal = true;
        continue;
      }
      final schemeIdx = entry.indexOf('://');
      if (schemeIdx > 0) {
        entry = entry.substring(schemeIdx + 3);
      }
      if (entry.isNotEmpty) patterns.add(entry);
    }
    return (patterns, bypassLocal);
  }

  /// 回环地址永远直连；`<local>` 匹配不带点的主机名；
  /// 含 `:port` 的模式按 `host:port` 匹配。
  static bool _shouldBypass(Uri url, SystemProxyState state) {
    final host = url.host.toLowerCase();
    if (host.isEmpty) return true;
    if (_isLoopback(host)) return true;
    if (state.bypassLocal && !host.contains('.') && !host.contains(':')) {
      return true;
    }
    for (final pattern in state.bypassPatterns) {
      if (_matchesPattern(pattern, host, url.port)) return true;
    }
    return false;
  }

  static bool _isLoopback(String host) {
    if (host == 'localhost' || host == '::1') return true;
    return host.startsWith('127.');
  }

  static bool _matchesPattern(String pattern, String host, int port) {
    var target = host;
    final colon = pattern.lastIndexOf(':');
    if (colon > 0 && int.tryParse(pattern.substring(colon + 1)) != null) {
      target = '$host:$port';
    }
    final regex =
        RegExp('^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$');
    return regex.hasMatch(target);
  }

  static SystemProxyState _buildState(
      String proxyServer, String proxyOverride) {
    final (http, https) = _parseProxyServer(proxyServer);
    final (patterns, bypassLocal) = _parseBypassList(proxyOverride);
    return SystemProxyState(
      httpProxy: http,
      httpsProxy: https,
      bypassPatterns: patterns,
      bypassLocal: bypassLocal,
    );
  }

  static SystemProxyState _readFromRegistry() {
    return using((arena) {
      final subKey = _regPath.toNativeUtf16(allocator: arena);

      int? readDword(String name) {
        final valueName = name.toNativeUtf16(allocator: arena);
        final data = arena<Uint32>();
        final cbData = arena<Uint32>()..value = sizeOf<Uint32>();
        final status = RegGetValue(HKEY_CURRENT_USER, subKey, valueName,
            RRF_RT_REG_DWORD, nullptr, data, cbData);
        return status == ERROR_SUCCESS ? data.value : null;
      }

      String? readString(String name) {
        final valueName = name.toNativeUtf16(allocator: arena);
        final cbData = arena<Uint32>();
        var status = RegGetValue(HKEY_CURRENT_USER, subKey, valueName,
            RRF_RT_REG_SZ, nullptr, nullptr, cbData);
        if (status != ERROR_SUCCESS || cbData.value == 0) return null;
        final buffer = arena.allocate<Utf16>(cbData.value);
        status = RegGetValue(HKEY_CURRENT_USER, subKey, valueName,
            RRF_RT_REG_SZ, nullptr, buffer, cbData);
        return status == ERROR_SUCCESS ? buffer.toDartString() : null;
      }

      // ProxyEnable=0 优先于残留的 ProxyServer；PAC 与 WPAD
      // 一律当作没有代理。
      if ((readDword('ProxyEnable') ?? 0) == 0) {
        return const SystemProxyState();
      }
      return _buildState(
        readString('ProxyServer') ?? '',
        readString('ProxyOverride') ?? '',
      );
    });
  }

  // 监听句柄与进程同生命周期；NativeCallable 存在这里，
  // 避免被垃圾回收掉。
  static int _hKey = 0;
  static int _hEvent = 0;
  static NativeCallable<_WaitOrTimerCallback>? _waitCallback;

  static void _startWatcher() {
    if (_watcherStarted) return;
    _watcherStarted = true;
    using((arena) {
      final subKey = _regPath.toNativeUtf16(allocator: arena);
      final phKey = arena<IntPtr>();
      if (RegOpenKeyEx(HKEY_CURRENT_USER, subKey, 0, KEY_NOTIFY, phKey) !=
          ERROR_SUCCESS) {
        KazumiLogger().w('Proxy: 系统代理监视启动失败（注册表键打开失败）');
        return;
      }
      _hKey = phKey.value;

      // 自动重置事件：每发一次信号，线程池上的等待只被唤醒一次。
      _hEvent = CreateEvent(nullptr, FALSE, FALSE, nullptr);
      if (_hEvent == 0) {
        _stopWatcher('CreateEvent 失败');
        return;
      }

      _waitCallback =
          NativeCallable<_WaitOrTimerCallback>.listener(_onWaitSignaled);

      final phWait = arena<IntPtr>();
      if (_registerWaitForSingleObject(phWait, _hEvent,
              _waitCallback!.nativeFunction, nullptr, INFINITE, 0) ==
          0) {
        _stopWatcher('RegisterWaitForSingleObject 失败');
        return;
      }

      if (!_armNotification()) _stopWatcher(null);
    });
  }

  /// 请求下一次一次性通知。要**先**重新挂上监听再去读注册表，
  /// 这样正好落在这个空档里的变更才能被这次读取捕获。
  static bool _armNotification() {
    final status = RegNotifyChangeKeyValue(
      _hKey,
      TRUE,
      REG_NOTIFY_CHANGE_NAME |
          REG_NOTIFY_CHANGE_LAST_SET |
          REG_NOTIFY_THREAD_AGNOSTIC,
      _hEvent,
      TRUE,
    );
    if (status != ERROR_SUCCESS) {
      KazumiLogger().w('Proxy: 系统代理变更通知注册失败 ($status)');
      return false;
    }
    return true;
  }

  static void _onWaitSignaled(Pointer<Void> context, int timerOrWaitFired) {
    _armNotification();
    _onRegistryChanged();
  }

  static void _stopWatcher(String? reason) {
    if (reason != null) {
      KazumiLogger().w('Proxy: 系统代理监视启动失败（$reason）');
    }
    _waitCallback?.close();
    _waitCallback = null;
    if (_hEvent != 0) {
      CloseHandle(_hEvent);
      _hEvent = 0;
    }
    if (_hKey != 0) {
      RegCloseKey(_hKey);
      _hKey = 0;
    }
  }

  static void _onRegistryChanged() {
    // 代理工具会连续写入好几个注册表值，把它们防抖成一次刷新。
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!refresh()) return;
      // 手动代理会盖过系统代理，所以客户端无需重建。
      if (GStorage.getSetting(SettingsKeys.proxyEnable)) return;
      ProxyManager.applyProxy();
    });
  }
}

/// `WAITORTIMERCALLBACK` 的函数签名：void (PVOID lpParameter, BOOLEAN TimerOrWaitFired)。
typedef _WaitOrTimerCallback = Void Function(Pointer<Void>, Uint8);

/// 在事件句柄上做线程池等待；package:win32 没有绑定这个函数。
final _registerWaitForSingleObject = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<
        Int32 Function(
            Pointer<IntPtr> phNewWaitObject,
            IntPtr hObject,
            Pointer<NativeFunction<_WaitOrTimerCallback>> callback,
            Pointer<Void> context,
            Uint32 dwMilliseconds,
            Uint32 dwFlags),
        int Function(
            Pointer<IntPtr> phNewWaitObject,
            int hObject,
            Pointer<NativeFunction<_WaitOrTimerCallback>> callback,
            Pointer<Void> context,
            int dwMilliseconds,
            int dwFlags)>('RegisterWaitForSingleObject');
