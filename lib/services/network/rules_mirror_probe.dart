import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/config/rules_repository_config.dart';
import 'package:kazumi/services/network/rules_mirror.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 一次规则仓库加速档位的探测结果。
///
/// 只用于在选择器里给用户一个「快 / 慢 / 不可用」的参考，不参与任何业务判断。
class RulesMirrorProbeResult {
  const RulesMirrorProbeResult({
    required this.mode,
    required this.latency,
    required this.reachable,
    this.notApplicable = false,
  });

  final RulesMirror mode;

  /// 拿到响应头所花的时间；[reachable] 为 false 时是探测超时上限。
  final Duration latency;

  final bool reachable;

  /// 该档位对探测目标不生效（GitCode 不镜像个人仓库），测出来的其实是回退档位。
  final bool notApplicable;

  String get label {
    if (notApplicable) {
      return '对当前仓库不生效';
    }
    if (!reachable) {
      // 失败也要给出真实耗时：超时是「等了这么久没回应」，不是「0 毫秒」。
      return '${latency.inMilliseconds} ms 无响应';
    }
    return '${latency.inMilliseconds} ms';
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'ms': latency.inMilliseconds,
    'reachable': reachable,
    'notApplicable': notApplicable,
  };

  static RulesMirrorProbeResult? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final mode = RulesMirror.values.asNameMap()[raw['mode']];
    final ms = raw['ms'];
    final reachable = raw['reachable'];
    if (mode == null || ms is! int || reachable is! bool) {
      return null;
    }
    return RulesMirrorProbeResult(
      mode: mode,
      latency: Duration(milliseconds: ms),
      reachable: reachable,
      notApplicable: raw['notApplicable'] == true,
    );
  }
}

/// 并发探测每种加速档位对规则仓库的可用性。
///
/// 探测目标是 `index.json` 的响应头：只发 GET 并立刻取消 body 读取，
/// 因此拿到的是真实可达性与首字节延迟，而非裸 TCP 连通。
class RulesMirrorProbe {
  const RulesMirrorProbe._();

  /// 默认单档位探测上限；已知偏慢的档位按 [RulesMirror.probeTimeout] 放宽。
  static const Duration timeout = Duration(milliseconds: 1500);

  /// 探测目标取「用户实际启用的第一个仓库」。
  ///
  /// 不能写死官方仓库：用户可能只启用个人仓库，而 GitCode 只镜像官方仓库，
  /// 写死会让 GitCode 档位测出官方仓库的速度，与实际读取路径完全不符。
  /// 没有启用任何仓库时退回官方仓库，保证总有可探测目标。
  static String get _probeTarget {
    final enabled = RulesRepositoryConfig.enabledRepositories();
    final repository = enabled.isEmpty
        ? ApiEndpoints.pluginShop
        : enabled.first.url;
    return RulesRepositoryConfig.catalogUri(repository);
  }

  /// 结果在一小时内可复用：重新打开发选项时直接显示上次结果，不再发请求。
  ///
  /// 缓存键里带着探测目标仓库，换了仓库或仓库被改动就自然失效；
  /// 用户点闪电按钮时走 [runStreaming] 的强制重测，不看缓存。
  static const Duration cacheTtl = Duration(hours: 1);

  /// 并发探测，每测完一个就通过 [onResult] 立即回调一次。
  ///
  /// 各档位互不等待：快的先显示，慢的等它自己回来。返回的 Future 在所有档位
  /// 都结束后完成，供调用方收尾。
  /// 永不抛异常：任何失败都折算成 [RulesMirrorProbeResult.reachable] 为 false。
  static Future<void> runStreaming(
    void Function(RulesMirrorProbeResult result) onResult,
  ) async {
    final target = _probeTarget;
    await Future.wait([
      for (final mode in RulesMirror.values)
        _probeOne(mode, target).then(onResult),
    ]);
  }

  /// 先吐缓存（若仍新鲜），否则重新探测，结果逐条回调后写回缓存。
  ///
  /// [force] 为 true 时忽略缓存，用于用户主动点「重新检测延迟」。
  static Future<void> runCached(
    void Function(RulesMirrorProbeResult result) onResult, {
    bool force = false,
  }) async {
    final target = _probeTarget;
    if (!force) {
      final cached = _readCache(target);
      if (cached != null) {
        for (final result in cached) {
          onResult(result);
        }
        return;
      }
    }
    final results = <RulesMirrorProbeResult>[];
    await runStreaming((result) {
      results.add(result);
      onResult(result);
    });
    await _writeCache(target, results);
  }

  static Map<String, dynamic> _decodeCache(String raw) {
    if (raw.trim().isEmpty) {
      return const {};
    }
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }

  /// 缓存新鲜且目标仓库一致时返回结果，否则返回 null。
  static List<RulesMirrorProbeResult>? _readCache(String target) {
    final cache = _decodeCache(
      GStorage.getSetting(SettingsKeys.rulesMirrorProbeCache),
    );
    if (cache['target'] != target) {
      return null;
    }
    final stampedAt = cache['at'];
    if (stampedAt is! int) {
      return null;
    }
    final age = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(stampedAt),
    );
    if (age.isNegative || age > cacheTtl) {
      return null;
    }
    final entries = cache['results'];
    if (entries is! List) {
      return null;
    }
    final results = <RulesMirrorProbeResult>[];
    for (final entry in entries) {
      final parsed = RulesMirrorProbeResult.fromJson(entry);
      if (parsed != null) {
        results.add(parsed);
      }
    }
    // 缺档位的缓存不完整，宁可重测也不给出半套结果。
    return results.length == RulesMirror.values.length ? results : null;
  }

  static Future<void> _writeCache(
    String target,
    List<RulesMirrorProbeResult> results,
  ) async {
    if (results.length != RulesMirror.values.length) {
      return;
    }
    await GStorage.putSetting(
      SettingsKeys.rulesMirrorProbeCache,
      jsonEncode({
        'target': target,
        'at': DateTime.now().millisecondsSinceEpoch,
        'results': [for (final result in results) result.toJson()],
      }),
    );
  }

  /// 一次性拿到全部结果，顺序与 [RulesMirror.values] 一致。
  static Future<List<RulesMirrorProbeResult>> run() async {
    final target = _probeTarget;
    return Future.wait([
      for (final mode in RulesMirror.values) _probeOne(mode, target),
    ]);
  }

  static Future<RulesMirrorProbeResult> _probeOne(
    RulesMirror mode,
    String target,
  ) async {
    final mapped = mode.map(target);
    // 有的档位对某些仓库只会回退到别的镜像（GitCode 只镜像官方仓库，
    // jsDelivr 只认 GitHub raw）：这时测出来的不是本档位的速度，标成不生效
    // 比给一个误导的毫秒数更有用。
    final notApplicable = mapped != null && !mode.appliesTo(target);
    final url = mapped ?? target;
    final limit = mode.probeTimeout;
    final watch = Stopwatch()..start();
    final dio = Dio(
      BaseOptions(
        connectTimeout: limit,
        receiveTimeout: limit,
        sendTimeout: limit,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    final cancel = CancelToken();
    try {
      await dio.get<void>(
        url,
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancel,
      );
      watch.stop();
      return RulesMirrorProbeResult(
        mode: mode,
        latency: watch.elapsed,
        reachable: true,
        notApplicable: notApplicable,
      );
    } catch (_) {
      watch.stop();
      return RulesMirrorProbeResult(
        mode: mode,
        latency: watch.elapsed > limit ? limit : watch.elapsed,
        reachable: false,
        notApplicable: notApplicable,
      );
    } finally {
      // 只关心响应头：立刻掐断 body，避免把整份目录读进内存。
      if (!cancel.isCancelled) {
        cancel.cancel('probe done');
      }
      dio.close(force: true);
    }
  }
}
