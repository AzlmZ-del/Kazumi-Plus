import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_logger_interceptor.dart';
import 'package:kazumi/request/core/ech_adapter.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/network/source_network_route.dart';
import 'package:kazumi/utils/http_headers.dart';

class DioFactory {
  DioFactory._();

  static Dio? _apiDio;
  static Dio? _bangumiDio;
  static Dio? _rulesRepoDio;
  static Dio? _pluginDio;
  static Dio? _downloadDio;
  static final Map<SourceNetworkRoute, Dio> _sourceDios = {};

  static Dio pluginForRoute(SourceNetworkRoute route) {
    return _sourceDios.putIfAbsent(
      route,
      () => _create(
        NetworkConfig(
          forceDirect: route.mode == SourceNetworkMode.direct,
          proxyHost: route.proxy?.host,
          proxyPort: route.proxy?.port,
          allowBadCertificates: route.allowBadCertificates,
        ),
        defaultHeaders: {
          'user-agent': getRandomHttpUA(),
          'accept-language': getRandomAcceptedLanguage(),
        },
      ),
    );
  }

  static Dio get apiDio => _apiDio ??= _create(
    NetworkConfig.fromSettings(),
    defaultHeaders: {'referer': '', 'user-agent': getRandomUA()},
  );

  static Dio get bangumiDio => _bangumiDio ??= _create(
    NetworkConfig.fromSettings(),
    defaultHeaders: {'referer': ''},
    ech: true,
  );

  static Dio get rulesRepoDio => _rulesRepoDio ??= _create(
    NetworkConfig.fromSettings(),
    defaultHeaders: {'user-agent': getRandomHttpUA()},
    ech: true,
  );

  static Dio get pluginDio => _pluginDio ??= _create(
    NetworkConfig.fromSettings(),
    defaultHeaders: {
      // Always use a non-browser UA for site scraping: a browser UA combined
      // with the BoringSSL fingerprint makes WAF flag us as a bot and return 403.
      // An explicit userAgent in the rule takes precedence.
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
    for (final dio in _sourceDios.values) {
      dio.close();
    }
    _sourceDios.clear();
    _apiDio = null;
    _bangumiDio = null;
    _rulesRepoDio = null;
    _pluginDio = null;
    _downloadDio = null;
  }

  static Dio _create(
    NetworkConfig config, {
    Map<String, dynamic> defaultHeaders = const {},
    bool ech = false,
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
    dio.httpClientAdapter = ech
        ? EchAdapter(fallback: config.createAdapter(), config: config)
        : config.createAdapter();
    if (config.enableLog) {
      dio.interceptors.add(DioLoggerInterceptor());
    }
    return dio;
  }
}
