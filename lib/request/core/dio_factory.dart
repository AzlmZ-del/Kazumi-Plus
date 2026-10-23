import 'package:dio/dio.dart';
import 'package:kazumi/request/core/bangumi_transport.dart';
import 'package:kazumi/request/core/dio_logger_interceptor.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/rules_mirror.dart';
import 'package:kazumi/utils/http_headers.dart';

class DioFactory {
  DioFactory._();

  static Dio? _apiDio;
  static Dio? _bangumiDio;
  static Dio? _rulesRepoDio;
  static Dio? _pluginDio;
  static Dio? _downloadDio;

  static Dio get apiDio => _apiDio ??= _create(
    NetworkConfig.fromSettings(),
    defaultHeaders: {'referer': '', 'user-agent': getRandomUA()},
  );

  static Dio get bangumiDio {
    if (_bangumiDio != null) return _bangumiDio!;
    final config = NetworkConfig.fromSettings();
    final dio = _create(
      config,
      defaultHeaders: {'referer': ''},
      interceptors: [BangumiAccelerationInterceptor()],
    );
    dio.httpClientAdapter = BangumiEchAdapter(
      fallback: dio.httpClientAdapter,
      config: config,
    );
    return _bangumiDio = dio;
  }

  static Dio get rulesRepoDio => _rulesRepoDio ??= _create(
    NetworkConfig.fromSettings(),
    defaultHeaders: {'user-agent': getRandomHttpUA()},
    interceptors: [_RulesMirrorInterceptor()],
  );

  static Dio get pluginDio => _pluginDio ??= _create(
    NetworkConfig.fromSettings(),
    defaultHeaders: {
      // 站点抓取一律用非浏览器 UA：浏览器 UA + BoringSSL 指纹会被 WAF 判为
      // 伪装爬虫并直接 403。规则显式配了 userAgent 时以规则为准。
      'user-agent': getRandomHttpUA(),
      'accept-language': getRandomAcceptedLanguage(),
    },
  );

  static Dio get downloadDio => _downloadDio ??= _create(
    NetworkConfig.fromSettings(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
    defaultHeaders: {'user-agent': getRandomUA()},
  );

  static Dio createForConfig(NetworkConfig config) {
    return _create(config);
  }

  static void reset() {
    // Retire old adapters without interrupting requests already in flight.
    _apiDio?.close();
    _bangumiDio?.close();
    _rulesRepoDio?.close();
    _pluginDio?.close();
    _downloadDio?.close();
    _apiDio = null;
    _bangumiDio = null;
    _rulesRepoDio = null;
    _pluginDio = null;
    _downloadDio = null;
  }

  static Dio _create(
    NetworkConfig config, {
    Map<String, dynamic> defaultHeaders = const {},
    List<Interceptor> interceptors = const [],
  }) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: config.connectTimeout,
        receiveTimeout: config.receiveTimeout,
        sendTimeout: config.sendTimeout,
        headers: defaultHeaders,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
    dio.httpClientAdapter = config.createAdapter();
    dio.interceptors.addAll(interceptors);
    if (config.enableLog) {
      dio.interceptors.add(DioLoggerInterceptor());
    }
    return dio;
  }
}

class _RulesMirrorInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // The mirror lives in one enum so the settings page and the request path
    // can never disagree about which host is in use.
    final mirrored = RulesMirror.current.map(options.uri.toString());
    if (mirrored != null) {
      KazumiLogger().d('Rules mirror: $mirrored');
      options.path = mirrored;
    }
    handler.next(options);
  }
}
