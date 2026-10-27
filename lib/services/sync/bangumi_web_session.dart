import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

/// bgm.tv 网页会话（用于「删除收藏」这类 OpenAPI 没有提供的能力）。
///
/// OpenAPI v0 没有删除收藏的接口，只有网页端 `/subject/<id>/remove?gh=<hash>`
/// 可用。网页端不认 Access Token，只认登录后的 `chii_auth` cookie，所以这里
/// 用邮箱 + 密码 + 官方验证码走一遍网页登录，拿到 cookie 后自行保存。
///
/// 登录必须直连：镜像站点不提供登录，加密 SNI（ECH）通道也不保证能过。
class BangumiWebSession {
  BangumiWebSession({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: _origin,
              // 删除接口靠 302 的 Location 判结果，必须自己接管跳转。
              followRedirects: false,
              validateStatus: (_) => true,
              responseType: ResponseType.plain,
              headers: {'User-Agent': _browserUserAgent},
            ),
          );

  static const String _origin = 'https://bgm.tv';

  /// 网页登录必须装成浏览器，否则站点可能下发不同页面。
  static const String _browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

  /// 登录态判据：条目页里 `CHOBITS_UID` 是当前登录用户 id，0 表示未登录。
  ///
  /// 站点把它写在一条合并声明里，形如
  /// `var SHOW_ROBOT = '0', CHOBITS_UID = 808296, CHOBITS_USERNAME = '808296', ...`
  /// —— `var` 只修饰第一个变量，所以匹配时**不能带 `var` 前缀**，否则永远匹配不到。
  static final RegExp _chobitsUidPattern = RegExp(r'CHOBITS_UID\s*=\s*(\d+)');

  final Dio _dio;

  /// 本次运行期间的会话 cookie（chii_sid / chii_sec / chii_sec_id）。
  final Map<String, String> _cookies = <String, String>{};

  /// 已登录用户的 UID，0 表示未登录。
  int _uid = 0;

  int get uid => _uid;

  String get _cookieHeader {
    final auth = _storedAuth;
    final merged = <String, String>{..._cookies};
    if (auth.isNotEmpty) {
      merged['chii_auth'] = auth;
    }
    return merged.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 组装请求头；没有 cookie 时不要发空的 `Cookie:`。
  Map<String, String> _headers([Map<String, String> extra = const {}]) {
    final cookie = _cookieHeader;
    return {if (cookie.isNotEmpty) 'Cookie': cookie, ...extra};
  }

  String get _storedAuth {
    try {
      return GStorage.getSetting(SettingsKeys.bangumiWebCookie);
    } catch (_) {
      return '';
    }
  }

  /// 本地是否保存过登录 cookie（不代表仍然有效）。
  bool get hasStoredCookie => _storedAuth.isNotEmpty;

  /// 上次成功取到的昵称，空字符串表示没记录过。
  ///
  /// 昵称不在登录链路里，要拿 Access Token 单独请求 `/v0/me`；
  /// 缓存一份到本地，进页面首帧就能显示「昵称 · UID」，不会先闪一下「已登录」。
  String get savedNickname {
    try {
      return GStorage.getSetting(SettingsKeys.bangumiWebNickname).trim();
    } catch (_) {
      return '';
    }
  }

  /// 记住昵称，供下次进页面直接显示。
  Future<void> saveNickname(String nickname) async {
    final value = nickname.trim();
    if (value.isEmpty) {
      return;
    }
    try {
      await GStorage.putSetting(SettingsKeys.bangumiWebNickname, value);
    } catch (e) {
      KazumiLogger().w('BangumiWeb: save nickname failed. $e');
    }
  }

  /// 上次成功登录时记住的账号（用于回填输入框）。
  String get savedEmail {
    try {
      return GStorage.getSetting(SettingsKeys.bangumiWebEmail);
    } catch (_) {
      return '';
    }
  }

  /// 上次成功登录时记住的密码（用于回填输入框）。
  String get savedPassword {
    try {
      return GStorage.getSetting(SettingsKeys.bangumiWebPassword);
    } catch (_) {
      return '';
    }
  }

  /// 上次成功登录拿到 cookie 的时间（毫秒时间戳），0 表示没记录过。
  ///
  /// 老版本登录的账号没有这个值，卡片上就不显示时间。
  int get savedLoginAt {
    try {
      return GStorage.getSetting(SettingsKeys.bangumiWebLoginAt);
    } catch (_) {
      return 0;
    }
  }

  /// 记住账号密码，下次打开卡片直接回填。
  Future<void> _rememberCredentials(String email, String password) async {
    try {
      await GStorage.putSetting(SettingsKeys.bangumiWebEmail, email);
      await GStorage.putSetting(SettingsKeys.bangumiWebPassword, password);
    } catch (e) {
      KazumiLogger().w('BangumiWeb: remember credentials failed. $e');
    }
  }

  void _absorbCookies(Response<dynamic> response) {
    final raw = response.headers.map['set-cookie'];
    if (raw == null) {
      return;
    }
    for (final entry in raw) {
      // 一条 set-cookie 可能塞了多个 cookie，按逗号切要小心 Expires 里的逗号，
      // 这里只处理属性段之前的主体。
      final body = entry.split(';').first.trim();
      final eq = body.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      final name = body.substring(0, eq).trim();
      final value = body.substring(eq + 1).trim();
      if (name.isEmpty) {
        continue;
      }
      _cookies[name] = value;
    }
  }

  /// 抓一张验证码，同时把会话 cookie 与 formhash 一起带出来。
  ///
  /// 验证码与登录必须使用同一条 cookie 会话，因此要在一次调用里连抓两次。
  Future<BangumiWebCaptcha> fetchCaptcha() async {
    _cookies.clear();
    KazumiLogger().i('BangumiWeb: fetching captcha');
    final loginPage = await _dio.get<String>(
      '/login',
      options: Options(headers: _headers()),
    );
    _absorbCookies(loginPage);

    final html = loginPage.data ?? '';
    final formhash = _matchGroup(
      html,
      RegExp(r'name="formhash"\s+value="([^"]+)"'),
    );

    final captcha = await _dio.get<List<int>>(
      '/signup/captcha',
      options: Options(headers: _headers(), responseType: ResponseType.bytes),
    );
    _absorbCookies(captcha);

    final image = Uint8List.fromList(captcha.data ?? const <int>[]);
    KazumiLogger().i(
      'BangumiWeb: captcha fetched. loginPage=${loginPage.statusCode}/'
      '${html.length}, formhash=${formhash.isEmpty ? 'MISSING' : 'ok'}, '
      'captcha=${captcha.statusCode}/${image.length} bytes, '
      'cookies=${_cookies.keys.join(',')}',
      forceLog: true,
    );

    return BangumiWebCaptcha(image: image, formhash: formhash);
  }

  /// 提交登录。成功时把 `chii_auth` 落盘并记录 uid。
  Future<void> login({
    required String email,
    required String password,
    required String captcha,
    required String formhash,
  }) async {
    KazumiLogger().i(
      'BangumiWeb: login submit. email=${_maskEmail(email)}, '
      'formhash=${formhash.isEmpty ? 'MISSING' : formhash}, '
      'captchaLen=${captcha.length}',
      forceLog: true,
    );
    final response = await _dio.post<String>(
      '/FollowTheRabbit',
      data: {
        'formhash': formhash,
        'email': email,
        'password': password,
        // 站点表单里输入框 id 是 captcha，但真正提交的字段名是
        // captcha_challenge_field；写成 captcha 会被静默忽略，
        // 返回原登录页且没有任何报错文案，登录必然失败。
        'captcha_challenge_field': captcha,
        // 还必须带上提交按钮自身的 name/value。缺了它站点会把
        // /FollowTheRabbit 当成普通页面渲染，直接返回一张登录页（HTTP 200、
        // 没有 <p class="text">），同样静默失败 —— 实测少了这一个字段，
        // 连「验证码错误」的提示都不会出现。
        'loginsubmit': '登录',
      },
      options: Options(
        headers: _headers({
          'Content-Type': 'application/x-www-form-urlencoded',
          'Referer': '$_origin/login',
        }),
      ),
    );
    _absorbCookies(response);

    final auth = _cookies['chii_auth'];
    if (auth == null || auth.isEmpty) {
      final reason = _extractLoginError(response.data ?? '');
      KazumiLogger().w(
        'BangumiWeb: login rejected. http=${response.statusCode}, '
        'reason=$reason, cookies=${_cookies.keys.join(',')}, '
        'rawSetCookie=${_describeSetCookie(response)}, '
        'bodyLen=${(response.data ?? '').length}, '
        'hasTextTag=${(response.data ?? '').contains('<p class="text">')}, '
        'hasErrMsg=${(response.data ?? '').contains('错误')}, '
        'bodyHead=${_bodyHead(response.data ?? '')}',
      );
      throw BangumiWebLoginException(reason);
    }

    KazumiLogger().i(
      'BangumiWeb: login got chii_auth. http=${response.statusCode}, '
      'len=${auth.length}',
      forceLog: true,
    );
    await GStorage.putSetting(SettingsKeys.bangumiWebCookie, auth);
    final ok = await _refreshUid();
    if (!ok) {
      KazumiLogger().w('BangumiWeb: login cookie stored but uid check failed');
      await GStorage.putSetting(SettingsKeys.bangumiWebCookie, '');
      throw const BangumiWebLoginException('登录态校验失败，请重试');
    }
    KazumiLogger().i('BangumiWeb: login success. uid=$_uid', forceLog: true);
    // 刚登录成功 = 刚校验过，顺手把缓存写满，进页面就不用再请求一次。
    await _saveValidation(true);
    // 记下拿到 cookie 的时间，仅用于卡片上显示「已登录 · 2026-10-25 23:49」。
    await GStorage.putSetting(
      SettingsKeys.bangumiWebLoginAt,
      DateTime.now().millisecondsSinceEpoch,
    );
    await _rememberCredentials(email, password);
  }

  /// 日志里不写完整邮箱。
  static String _maskEmail(String email) {
    final at = email.indexOf('@');
    if (at <= 1) {
      return '***';
    }
    return '${email.substring(0, 2)}***${email.substring(at)}';
  }

  /// 把 `set-cookie` 原始条目脱敏成「第几条 / 含哪些 cookie 名」。
  ///
  /// 只打印 cookie 名与段数，绝不打印值，避免把 `chii_auth` 这类凭证写进日志。
  static String _describeSetCookie(Response<dynamic> response) {
    final raw = response.headers.map['set-cookie'];
    if (raw == null || raw.isEmpty) {
      return '<none>';
    }
    final parts = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      final names = <String>[];
      // 按「, xxx=」的形式切分合并的多个 cookie；Expires 里的逗号后面不跟
      // `name=` 形态，因此不会被误切。
      for (final piece in entry.split(RegExp(r',\s*(?=[^;,\s]+=)'))) {
        final body = piece.split(';').first.trim();
        final eq = body.indexOf('=');
        if (eq > 0) {
          names.add(body.substring(0, eq).trim());
        }
      }
      parts.add('#$i[${names.join('|')}]');
    }
    return parts.join(' ');
  }

  /// 失败页正文开头，压成一行短摘要，供比对站点返回的真实提示。
  static String _bodyHead(String html) {
    final text = html
        .replaceAll(RegExp(r'<script[\s\S]*?</script>'), ' ')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>'), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.length <= 120 ? text : '${text.substring(0, 120)}…';
  }

  /// 校验本地 cookie 是否仍有效（用轻量条目页读 CHOBITS_UID）。
  ///
  /// 校验结果会连同时间戳一起落盘，供 [cachedValidation] 在缓存窗口内复用。
  Future<bool> validate() async {
    if (!hasStoredCookie) {
      _uid = 0;
      await _saveValidation(false);
      return false;
    }
    final ok = await _refreshUid();
    await _saveValidation(ok);
    return ok;
  }

  /// App 启动时预热一次登录状态。
  ///
  /// 判据和进设置页时完全一致：缓存窗口内直接沿用上次结论，过期才真发一次
  /// `/subject/1`。窗口长度就是「网页登录」卡片里那个检测间隔滑块。
  /// 没有存过 cookie（从没登录 / 已退出）时直接返回，不发请求。
  Future<void> warmUpOnStartup() async {
    if (!hasStoredCookie) {
      return;
    }
    if (cachedValidation != null) {
      return;
    }
    try {
      final ok = await validate();
      KazumiLogger().i('BangumiWeb: startup warm-up -> $ok');
    } catch (e) {
      KazumiLogger().w('BangumiWeb: startup warm-up failed. $e');
    }
  }

  /// 检测登录状态的间隔（小时），默认 6，范围 1~24。
  int get _cacheHours {
    try {
      final v = GStorage.getSetting(
        SettingsKeys.bangumiWebValidateIntervalHours,
      );
      return v.clamp(1, 24);
    } catch (_) {
      return 6;
    }
  }

  /// 上一次校验的缓存结论。
  ///
  /// 返回 null 表示「没有可用缓存」——从没校验过、或者已经超过检测间隔，
  /// 这时调用方应该真正发一次请求。缓存只省掉进页面时那次 `/subject/1`。
  bool? get cachedValidation {
    try {
      final at = GStorage.getSetting(SettingsKeys.bangumiWebValidatedAt);
      if (at <= 0) {
        return null;
      }
      final age = DateTime.now().millisecondsSinceEpoch - at;
      if (age < 0 || age > _cacheHours * 60 * 60 * 1000) {
        return null;
      }
      final ok = GStorage.getSetting(SettingsKeys.bangumiWebValidatedOk);
      if (ok) {
        // 命中缓存也要把 UID 补回来，副标题才不会退化成「已登录」。
        final cachedUid = GStorage.getSetting(SettingsKeys.bangumiWebUid);
        if (cachedUid > 0) {
          _uid = cachedUid;
        }
      }
      return ok;
    } catch (_) {
      return null;
    }
  }

  /// 把这次校验的结论与时间一起写盘。
  Future<void> _saveValidation(bool ok) async {
    try {
      await GStorage.putSetting(
        SettingsKeys.bangumiWebValidatedAt,
        DateTime.now().millisecondsSinceEpoch,
      );
      await GStorage.putSetting(SettingsKeys.bangumiWebValidatedOk, ok);
      await GStorage.putSetting(SettingsKeys.bangumiWebUid, ok ? _uid : 0);
    } catch (e) {
      KazumiLogger().w('BangumiWeb: save validation cache failed. $e');
    }
  }

  /// 让缓存立刻作废（退出登录、改密码后调用）。
  Future<void> invalidateValidationCache() async {
    try {
      await GStorage.putSetting(SettingsKeys.bangumiWebValidatedAt, 0);
    } catch (e) {
      KazumiLogger().w('BangumiWeb: clear validation cache failed. $e');
    }
  }

  Future<bool> _refreshUid() async {
    // /subject/1 页面约 57 KB，比首页小得多，够用来读 CHOBITS_UID。
    final response = await _dio.get<String>(
      '/subject/1',
      options: Options(headers: _headers()),
    );
    _absorbCookies(response);
    final uidText = _matchGroup(response.data ?? '', _chobitsUidPattern);
    _uid = int.tryParse(uidText) ?? 0;
    return _uid > 0;
  }

  Future<void> logout() async {
    _cookies.clear();
    _uid = 0;
    await GStorage.putSetting(SettingsKeys.bangumiWebCookie, '');
    // 时间戳跟着登录态一起清掉，避免下次登录前还显示上一次的时间。
    await GStorage.putSetting(SettingsKeys.bangumiWebLoginAt, 0);
    // 昵称也跟着清，否则下次进页面会先显示上一个账号的昵称。
    await GStorage.putSetting(SettingsKeys.bangumiWebNickname, '');
    // 记住的账号密码同样清掉：用户点「退出登录」就是要彻底退干净，
    // 输入框里留着上一次的邮箱密码等于没退（2026-10-28 用户要求）。
    await GStorage.putSetting(SettingsKeys.bangumiWebEmail, '');
    await GStorage.putSetting(SettingsKeys.bangumiWebPassword, '');
    // 缓存也跟着作废，否则退出登录后再进页面会先闪一下「已登录」。
    await invalidateValidationCache();
  }

  /// 检测到 cookie 已失效时调用：清掉本地这份过期 cookie。
  ///
  /// 与 [logout] 的区别是**只清登录态**：记住的账号密码、检测间隔都保留，
  /// 用户重新登录时输入框还是回填好的。时间戳/昵称/UID 一并清掉，
  /// 免得界面上还挂着上一次登录的痕迹。
  Future<void> clearInvalidCookie() async {
    _cookies.clear();
    _uid = 0;
    await GStorage.putSetting(SettingsKeys.bangumiWebCookie, '');
    await GStorage.putSetting(SettingsKeys.bangumiWebLoginAt, 0);
    await GStorage.putSetting(SettingsKeys.bangumiWebNickname, '');
    await invalidateValidationCache();
  }

  /// 删除一条 Bangumi 收藏。
  ///
  /// 判据来自实测：删除请求一律返回 302，只能靠 Location 分辨结果。
  /// - Location 为空  → 真的删掉了
  /// - Location `/`   → 本来就没收藏
  /// - Location `/subject/<id>` → 删除失败（gh 失效或登录失效）
  Future<BangumiWebDeleteResult> deleteCollection(int subjectId) async {
    if (!hasStoredCookie) {
      KazumiLogger().w('BangumiWeb: delete aborted, no stored cookie');
      return BangumiWebDeleteResult.expired;
    }

    KazumiLogger().i('BangumiWeb: delete start. subject=$subjectId');
    final subjectPage = await _dio.get<String>(
      '/subject/$subjectId',
      options: Options(headers: _headers()),
    );
    _absorbCookies(subjectPage);
    final html = subjectPage.data ?? '';

    final uidText = _matchGroup(html, _chobitsUidPattern);
    _uid = int.tryParse(uidText) ?? 0;
    if (_uid <= 0) {
      KazumiLogger().w(
        'BangumiWeb: delete aborted, cookie expired. '
        'http=${subjectPage.statusCode} size=${html.length} uid=$_uid',
      );
      return BangumiWebDeleteResult.expired;
    }

    final gh = _matchGroup(
      html,
      RegExp(r"eraseSubjectCollect\(\s*\d+\s*,\s*'([a-fA-F0-9]+)'"),
    );
    if (gh.isEmpty) {
      // 页面里没有 delete 表单，说明这条压根没收藏在 Bangumi。
      KazumiLogger().i(
        'BangumiWeb: delete skipped, not collected on bangumi. '
        'subject=$subjectId uid=$_uid',
      );
      return BangumiWebDeleteResult.notCollected;
    }

    final response = await _dio.get<String>(
      '/subject/$subjectId/remove',
      queryParameters: {'gh': gh},
      options: Options(headers: _headers()),
    );
    _absorbCookies(response);

    final locations = response.headers.map['location'];
    final location =
        (locations != null && locations.isNotEmpty ? locations.first : '')
            .trim();
    KazumiLogger().i(
      'BangumiWeb: delete response. subject=$subjectId gh=$gh '
      'http=${response.statusCode} location=${location.isEmpty ? '<empty>' : location}',
      forceLog: true,
    );
    if (location.isEmpty) {
      return BangumiWebDeleteResult.deleted;
    }
    if (location == '/' || location == _origin || location == '$_origin/') {
      return BangumiWebDeleteResult.notCollected;
    }
    return BangumiWebDeleteResult.failed;
  }

  static String _matchGroup(String source, RegExp pattern) {
    final match = pattern.firstMatch(source);
    return match?.group(1) ?? '';
  }

  static String _extractLoginError(String html) {
    final match = RegExp(r'<p class="text">([^<]+)</p>').firstMatch(html);
    final message = match?.group(1)?.trim() ?? '';
    if (message.isNotEmpty) {
      return message;
    }
    return '登录失败，请检查账号密码与验证码';
  }
}

/// 验证码图片 + 本次会话的 formhash。
class BangumiWebCaptcha {
  const BangumiWebCaptcha({required this.image, required this.formhash});

  final Uint8List image;
  final String formhash;

  String get base64Image => base64Encode(image);
}

enum BangumiWebDeleteResult {
  /// 远端已删除。
  deleted,

  /// 远端本来就没有这条收藏。
  notCollected,

  /// cookie 失效，需要重新登录。
  expired,

  /// 请求被拒（gh 失效等）。
  failed,
}

class BangumiWebLoginException implements Exception {
  const BangumiWebLoginException(this.message);

  final String message;

  @override
  String toString() => message;
}
