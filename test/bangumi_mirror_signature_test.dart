import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/bangumi_mirror_signature.dart';

void main() {
  group('isSignatureProtectedBangumiPath', () {
    test('covers search, comments and nothing else', () {
      expect(isSignatureProtectedBangumiPath('POST', '/v0/search/subjects'),
          isTrue);
      expect(
          isSignatureProtectedBangumiPath(
              'GET', '/p1/subjects/253/comments'),
          isTrue);
      expect(
          isSignatureProtectedBangumiPath(
              'GET', '/p1/episodes/1027/comments'),
          isTrue);
      expect(
          isSignatureProtectedBangumiPath(
              'GET', '/p1/characters/1/comments'),
          isTrue);
    });

    test('leaves unprotected endpoints on the mirror', () {
      expect(isSignatureProtectedBangumiPath('GET', '/p1/calendar'), isFalse);
      expect(isSignatureProtectedBangumiPath('GET', '/p1/subjects/253'),
          isFalse);
      expect(isSignatureProtectedBangumiPath('POST', '/v0/subjects/search'),
          isFalse);
      expect(
          isSignatureProtectedBangumiPath('GET', '/p1/subjects/253/persons'),
          isFalse);
    });

    test('does not treat a comment prefix as a protected path', () {
      expect(
          isSignatureProtectedBangumiPath('GET', '/v0/search/subjects'),
          isFalse);
      expect(
          isSignatureProtectedBangumiPath(
              'GET', '/p1/subjects/253/comments/1'),
          isFalse);
    });
  });

  group('hasBangumiMirrorCredentials', () {
    test('is false for local builds without dart-define values', () {
      // The test binary is built without KAZUMI_APPID / KAZUMI_KEY, which is
      // exactly the local-build situation this guard exists for.
      expect(hasBangumiMirrorCredentials, isFalse);
    });
  });
}
