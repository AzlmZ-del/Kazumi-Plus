// 客户端签名流程要用的 DanDanPlay 接口凭据。
// Release/PR 的 CI 通过 --dart-define=DANDANAPI_APPID / DANDANAPI_KEY 注入。
const Map<String, String> dandanCredentials = {
  'id': String.fromEnvironment('DANDANAPI_APPID'),
  'value': String.fromEnvironment('DANDANAPI_KEY'),
};
