import 'package:kazumi/utils/bangumi_mirror_credentials.dart';

/// Kazumi 镜像只对「用构建时打入的应用凭据签名过」的请求开放这些接口。
/// 其它请求一律 401，尽管官方 Bangumi 接口对同样的路径是允许匿名的。
///
/// 本地构建没有 `KAZUMI_APPID` / `KAZUMI_KEY`（它们来自 CI secrets），
/// 所以这些路径必须继续走官方主机，不能被改写到镜像。
bool isSignatureProtectedBangumiPath(String method, String path) {
  if (method == 'POST' && path == '/v0/search/subjects') return true;
  if (method != 'GET') return false;
  return (path.startsWith('/p1/subjects/') && path.endsWith('/comments')) ||
      (path.startsWith('/p1/episodes/') && path.endsWith('/comments')) ||
      (path.startsWith('/p1/characters/') && path.endsWith('/comments'));
}

/// 当前构建是否带镜像签名凭据。
bool get hasBangumiMirrorCredentials =>
    bangumiMirrorCredentials['id']!.isNotEmpty &&
    bangumiMirrorCredentials['value']!.isNotEmpty;
