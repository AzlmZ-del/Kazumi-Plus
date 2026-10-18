import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/core/bangumi_transport.dart';

/// Captures what the interceptor decided without performing any request.
class _CapturingHandler extends RequestInterceptorHandler {
  bool called = false;
  bool forced = false;
  RequestOptions? captured;

  @override
  void next(RequestOptions options) {
    called = true;
    captured = options;
  }

  @override
  void resolve(Response response, [bool callFollowingResponseInterceptor = false]) {}

  @override
  void reject(DioException error, [bool callFollowingErrorInterceptor = false]) {}
}

void main() {
  group('BangumiAccelerationInterceptor force-official flag', () {
    test('leaves the host untouched and consumes the flag', () {
      final interceptor = BangumiAccelerationInterceptor();
      final options = RequestOptions(
        path: 'https://next.bgm.tv/p1/subjects/74435/comments',
        extra: {bangumiForceOfficialKey: true},
      );
      final handler = _CapturingHandler();

      interceptor.onRequest(options, handler);

      expect(handler.called, isTrue);
      expect(
        handler.captured!.uri.host,
        'next.bgm.tv',
        reason: 'the forced request must not be rewritten to the mirror',
      );
      expect(
        handler.captured!.extra.containsKey(bangumiForceOfficialKey),
        isFalse,
        reason: 'the flag is single use, otherwise a retry stays pinned',
      );
    });

    test('a request without the flag still reaches the handler', () {
      final interceptor = BangumiAccelerationInterceptor();
      final options = RequestOptions(
        path: 'https://example.com/rules/index.json',
      );
      final handler = _CapturingHandler();

      interceptor.onRequest(options, handler);

      expect(handler.called, isTrue);
      expect(handler.captured!.uri.host, 'example.com');
    });
  });
}
