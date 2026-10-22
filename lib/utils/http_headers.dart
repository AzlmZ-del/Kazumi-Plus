import 'dart:math';

import 'package:kazumi/utils/constants.dart';

final _random = Random();

/// 浏览器 UA：仅供 WebView 使用。
///
/// 直接用于 HTTP 请求会因 UA 与 TLS 指纹不一致而被 Cloudflare 一类 WAF 拦截，
/// HTTP 请求请改用 [getRandomHttpUA]。
String getRandomUA() {
  return userAgentsList[_random.nextInt(userAgentsList.length)];
}

/// 非浏览器 UA：供 `HttpClient` / Dio 等原生 HTTP 请求使用。
String getRandomHttpUA() {
  return httpClientUserAgentsList[
      _random.nextInt(httpClientUserAgentsList.length)];
}

/// WebView 应使用的 UA：规则自带 UA 优先，未配置时回落到浏览器 UA 池。
///
/// WebView 必须拿完整浏览器 UA，否则站点会下发移动页或非 JS 页面；但一旦规则
/// 显式配了浏览器 UA，WebView 也必须用它——Cloudflare 一类 WAF 会把
/// `cf_clearance` 与签发时的 UA 绑定，若 WebView 用随机 UA 通过验证、后续 dio
/// 却发规则 UA，这张 cookie 会立刻失效并重新下发验证页。
///
/// 让两边同源是「规则 UA 最高优先级」能真正成立的前提：验证时 UA 就等于规则
/// UA，[PluginCookieManager] 记下的 verified UA 与 `config.userAgent` 一致，
/// 优先级链上两层不会互相打架。
///
/// 规则 UA 若不是浏览器 UA（例如 `okhttp/4.9.0`），则回落到随机浏览器 UA：
/// 这类 UA 进 WebView 只会拿到非 JS 页面，验证根本跑不通。此时 clearance
/// cookie 绑定的是回落后的浏览器 UA，而 [RuleEngine] 的优先级里 verified UA
/// 仍高于规则 UA，所以链路依旧自洽——只是这条规则不参与 UA 对齐。
String resolveWebviewUserAgent(String ruleUserAgent) {
  final trimmed = ruleUserAgent.trim();
  // 只接受浏览器 UA：客户端库 UA（okhttp、Dart 等）进 WebView 会拿到
  // 非 JS 页面，验证与播放解析都跑不通。
  if (trimmed.startsWith('Mozilla/')) return trimmed;
  return getRandomUA();
}

String getRandomAcceptedLanguage() {
  return acceptLanguageList[_random.nextInt(acceptLanguageList.length)];
}
