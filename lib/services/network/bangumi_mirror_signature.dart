import 'package:kazumi/utils/bangumi_mirror_credentials.dart';

/// Endpoints the Kazumi mirror only serves to requests signed with the app
/// credentials baked in at build time. Everyone else gets a 401, even though
/// the official Bangumi API answers the same paths anonymously.
///
/// Local builds have no `KAZUMI_APPID` / `KAZUMI_KEY` (they come from CI
/// secrets), so these paths must keep talking to the official host instead of
/// being rewritten to the mirror.
bool isSignatureProtectedBangumiPath(String method, String path) {
  if (method == 'POST' && path == '/v0/search/subjects') return true;
  if (method != 'GET') return false;
  return (path.startsWith('/p1/subjects/') && path.endsWith('/comments')) ||
      (path.startsWith('/p1/episodes/') && path.endsWith('/comments')) ||
      (path.startsWith('/p1/characters/') && path.endsWith('/comments'));
}

/// Whether this build carries the mirror signing credentials.
bool get hasBangumiMirrorCredentials =>
    bangumiMirrorCredentials['id']!.isNotEmpty &&
    bangumiMirrorCredentials['value']!.isNotEmpty;
