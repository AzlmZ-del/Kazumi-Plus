import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/ech_adapter.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/bangumi_mirror_credentials.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/crypto.dart';

class BangumiClient {
  BangumiClient._();

  static final BangumiClient instance = BangumiClient._();

  /// Request extra that forces a request onto the official host, bypassing
  /// mirror routing. Mirrors forward without credentials, so R18-scoped data
  /// (comments, item details) comes back as an upstream error there.
  static const forceOfficialKey = 'bangumiForceOfficial';

  Future<dynamic> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    bool requiresAuth = false,
    bool anonymous = false,
    String? accessToken,
    CancelToken? cancelToken,
    Map<String, dynamic>? extra,
  }) async {
    try {
      final response = await DioFactory.bangumiDio.get(
        url,
        queryParameters: queryParameters,
        options: Options(
          headers: _headers(
            requiresAuth: requiresAuth,
            anonymous: anonymous,
            accessToken: accessToken,
            url: url,
            method: 'GET',
          ),
          extra: extra,
        ),
        cancelToken: cancelToken,
      );
      return response.data;
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Future<dynamic> post(
    String url, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    bool requiresAuth = false,
    bool anonymous = false,
    String? accessToken,
    CancelToken? cancelToken,
    Map<String, dynamic>? extra,
  }) async {
    final uri = Uri.parse(url);
    final route = _route(uri, requiresAuth, extra);
    try {
      final response = await DioFactory.bangumiDio.post(
        route == BangumiAcceleration.mirror
            ? ApiEndpoints.bangumiMirrorDomain +
                  uri.path +
                  (uri.hasQuery ? '?${uri.query}' : '')
            : url,
        data: data,
        queryParameters: route == BangumiAcceleration.mirror
            ? null
            : queryParameters,
        options: Options(
          headers: _headers(
            route: route,
            requiresAuth: requiresAuth,
            anonymous: anonymous,
            accessToken: accessToken,
            url: url,
            method: 'POST',
            path: uri.path,
            data: data,
          ),
          extra: route == BangumiAcceleration.ech ? echExtra : extra,
        ),
        cancelToken: cancelToken,
      );
      return response.data;
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  /// User-scoped requests always reach the official API over ECH, unless the
  /// caller explicitly forces the official host for an unauthenticated retry.
  BangumiAcceleration _route(
    Uri uri,
    bool requiresAuth,
    Map<String, dynamic>? extra,
  ) {
    if (extra?[forceOfficialKey] == true) return BangumiAcceleration.direct;
    if (!ApiEndpoints.bangumiPublicApiHosts.contains(uri.host)) {
      return BangumiAcceleration.direct;
    }
    return requiresAuth ? BangumiAcceleration.ech : BangumiAcceleration.current;
  }

  Map<String, dynamic> _headers({
    BangumiAcceleration? route,
    required bool requiresAuth,
    bool anonymous = false,
    String? accessToken,
    required String url,
    required String method,
    String? path,
    Object? data,
  }) {
    final headers = <String, dynamic>{...bangumiHTTPHeader};
    final token =
        (accessToken ??
                GStorage.getSetting<String>(SettingsKeys.bangumiAccessToken))
            .trim();
    // Only send the token where the API actually needs it. `bangumiSyncEnable`
    // is deliberately not consulted: it used to attach the token to every
    // request, so an expired token turned public endpoints (`next.bgm.tv` p1
    // series) into 401 and blanked the whole browse UI. `anonymous` lets the
    // auth fallback retry without the credentials the server just rejected.
    if (requiresAuth && !anonymous && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    if (_shouldSignProtectedMirrorRequest(url, method)) {
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final body = data == null ? '' : jsonEncode(data);
      headers['X-AppId'] = bangumiMirrorCredentials['id'];
      headers['X-Timestamp'] = timestamp;
      headers['X-Signature'] = generateBangumiMirrorSearchSignature(
        method: method,
        path: Uri.parse(url).path,
        body: body,
        timestamp: timestamp,
      );
    }
    return headers;
  }

  bool _shouldSignProtectedMirrorRequest(String url, String method) {
    final uri = Uri.parse(url);
    if (BangumiAcceleration.current != BangumiAcceleration.mirror ||
        !ApiEndpoints.bangumiPublicApiHosts.contains(uri.host)) {
      return false;
    }
    final path = uri.path;
    if (method == 'POST' && path == '/v0/search/subjects') {
      return true;
    }
    if (method != 'GET') {
      return false;
    }
    return path.startsWith('/p1/subjects/') && path.endsWith('/comments') ||
        path.startsWith('/p1/episodes/') && path.endsWith('/comments') ||
        path.startsWith('/p1/characters/') && path.endsWith('/comments');
  }
}
