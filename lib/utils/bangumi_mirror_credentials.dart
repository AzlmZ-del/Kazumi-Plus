// 搜索签名流程要用的 Bangumi 镜像接口凭据。
// Release/PR 的 CI 通过 --dart-define=KAZUMI_APPID / KAZUMI_KEY 注入。
const Map<String, String> bangumiMirrorCredentials = {
  'id': String.fromEnvironment('KAZUMI_APPID'),
  'value': String.fromEnvironment('KAZUMI_KEY'),
};
