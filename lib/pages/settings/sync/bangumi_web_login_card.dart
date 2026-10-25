import 'package:flutter/material.dart';

import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/bean/widget/tonal_card.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/bangumi_web_session.dart';

/// 同步设置里的「网页登录」卡片。
///
/// Bangumi 的 OpenAPI 没有删除收藏的接口，只有网页端能删。这里用账号密码
/// 走一次网页登录拿到 `chii_auth`，之后删除收藏才走得了远端。
class BangumiWebLoginCard extends StatefulWidget {
  const BangumiWebLoginCard({super.key});

  @override
  State<BangumiWebLoginCard> createState() => _BangumiWebLoginCardState();
}

class _BangumiWebLoginCardState extends State<BangumiWebLoginCard> {
  final _session = BangumiWebSession();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _captchaController = TextEditingController();

  BangumiWebCaptcha? _captcha;
  bool _obscure = true;
  bool _loadingCaptcha = false;
  bool _loggingIn = false;
  bool _checking = false;
  bool _loggedIn = false;
  String? _error;

  /// Bangumi 昵称。网页登录只拿得到 UID，昵称要拿 Access Token 打一次
  /// `/v0/me`；拿不到就退回 UID，不影响登录本身。
  String _nickname = '';

  /// 检测登录状态的间隔（小时），1~24，默认 6。
  late int _intervalHours;

  @override
  void initState() {
    super.initState();
    // 「登录并保存」会把账号密码记下来，下次进来直接回填，不用再敲一遍。
    _emailController.text = _session.savedEmail;
    _passwordController.text = _session.savedPassword;
    _intervalHours =
        GStorage.getSetting(SettingsKeys.bangumiWebValidateIntervalHours)
            .clamp(1, 24);
    if (_session.hasStoredCookie) {
      // 缓存窗口内直接用上次结论，省掉进页面那次 /subject/1 请求；
      // 没有缓存（从没校验过 / 已过期）才真去查。
      final cached = _session.cachedValidation;
      if (cached != null) {
        _loggedIn = cached;
        if (cached) _loadNickname();
      } else {
        _validate();
      }
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _captchaController.dispose();
    super.dispose();
  }

  Future<void> _validate() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final ok = await _session.validate();
      KazumiLogger().i('BangumiWebUI: session validate -> $ok');
      if (mounted) {
        setState(() => _loggedIn = ok);
      }
      if (ok) await _loadNickname();
    } catch (e, stackTrace) {
      KazumiLogger().w(
        'BangumiWebUI: session validate threw',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _loggedIn = false);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// 用已保存的 Access Token 取一次昵称，仅用于副标题显示。
  ///
  /// 网页登录这条链路只有 cookie，拿不到昵称；失败一律静默，退回 UID。
  Future<void> _loadNickname() async {
    final token = GStorage.getSetting(SettingsKeys.bangumiAccessToken).trim();
    if (token.isEmpty) return;
    try {
      final user = await BangumiApi.getCurrentUser(accessToken: token);
      final name = user?.nickname.trim() ?? '';
      if (mounted && name.isNotEmpty) {
        setState(() => _nickname = name);
      }
    } catch (e) {
      KazumiLogger().w('BangumiWebUI: load nickname failed', error: e);
    }
  }

  Future<void> _refreshCaptcha() async {
    if (_loadingCaptcha) return;
    setState(() {
      _loadingCaptcha = true;
      _error = null;
    });
    try {
      final captcha = await _session.fetchCaptcha();
      if (mounted) {
        setState(() {
          _captcha = captcha;
          _captchaController.clear();
        });
      }
    } catch (e, stackTrace) {
      KazumiLogger().e(
        'BangumiWebUI: captcha fetch failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _error = '验证码获取失败：${_describe(e)}');
      }
    } finally {
      if (mounted) setState(() => _loadingCaptcha = false);
    }
  }

  Future<void> _login() async {
    if (_loggingIn) return;
    final captcha = _captcha;
    if (captcha == null) {
      setState(() => _error = '请先获取验证码');
      return;
    }
    if (_emailController.text.trim().isEmpty ||
        _passwordController.text.isEmpty) {
      setState(() => _error = '请填写账号与密码');
      return;
    }
    if (_captchaController.text.trim().isEmpty) {
      setState(() => _error = '请填写验证码');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _loggingIn = true;
      _error = null;
    });
    try {
      await _session.login(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        captcha: _captchaController.text.trim(),
        formhash: captcha.formhash,
      );
      if (mounted) {
        setState(() {
          _loggedIn = true;
          // 「登录并保存」：账号与密码留在输入框里，不随登录成功清空。
          _captchaController.clear();
          _captcha = null;
        });
        KazumiDialog.showToast(message: '已登录，账号密码已保存');
      }
      await _loadNickname();
    } catch (e, stackTrace) {
      KazumiLogger().w(
        'BangumiWebUI: login failed. ${_describe(e)}',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _error = _describe(e));
        // 验证码一次性消费，失败后必须换一张。
        await _refreshCaptcha();
      }
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _logout() async {
    await _session.logout();
    if (!mounted) return;
    setState(() {
      _loggedIn = false;
      _nickname = '';
      _captcha = null;
      _captchaController.clear();
      // 退出的是登录态，不是「已保存的账号密码」——两回事，输入框保持原样。
    });
    KazumiDialog.showToast(message: '已退出网页登录');
  }

  static String _describe(Object error) {
    if (error is BangumiWebLoginException) {
      return error.message;
    }
    return '网络请求失败，请检查网络后重试';
  }

  bool get _busy => _loggingIn || _loadingCaptcha || _checking;

  /// 副标题里的账号标识：优先「昵称 · UID 808296」，没有昵称就只给 UID。
  ///
  /// 用 Access Token 换昵称，失败时 `_nickname` 为空，这里自动降级。
  String get _accountLabel {
    final uid = _session.uid;
    final uidText = uid > 0 ? 'UID $uid' : '';
    if (_nickname.isNotEmpty) {
      return uidText.isEmpty ? _nickname : '$_nickname · $uidText';
    }
    return uidText.isEmpty ? '已登录，可删除 Bangumi 收藏' : '已登录 · $uidText';
  }

  /// 卡片内部那一行：显示拿到 cookie 的时间，例如「已登录 · 2026-10-25 23:49」。
  ///
  /// 老版本登录的账号没有存时间戳（值为 0），此时只显示「已登录」。
  String get _loginLabel {
    final at = _session.savedLoginAt;
    if (at <= 0) return '已登录';
    final t = DateTime.fromMillisecondsSinceEpoch(at);
    String two(int v) => v.toString().padLeft(2, '0');
    return '已登录 · ${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  /// 三个输入框与验证码图片统一高度，避免一行里三个控件高低不齐。
  static const double _fieldHeight = 48;

  /// 圆角跟另外三个输入框对齐：`const OutlineInputBorder()` 的默认值就是 4。
  static const BorderRadius _fieldRadius = BorderRadius.all(Radius.circular(4));

  InputDecoration _fieldDecoration({
    required String labelText,
    Widget? suffixIcon,
  }) =>
      InputDecoration(
        labelText: labelText,
        border: const OutlineInputBorder(),
        isDense: true,
        // 垂直内边距留小一点：外面已经用 SizedBox 锁死 _fieldHeight，
        // 这里只要保证文字放得下，剩余高度由 InputDecorator 自己居中，
        // 系统字体放大时也不会撑破 48。
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        suffixIcon: suffixIcon,
      );

  @override
  Widget build(BuildContext context) => TonalCard(
        child: ExpansionTile(
          // 用同步读本地 cookie 判断，而不是异步校验出来的 `_loggedIn`：
          // `initiallyExpanded` 只在首帧读一次，等 `_validate()` 回来时已经晚了，
          // 结果就是「明明已登录却仍然展开」。`hasStoredCookie` 直接看设置项，
          // 首帧就是对的，与上方「Bangumi 账号」卡片的 `!configured` 行为一致。
          initiallyExpanded: !_session.hasStoredCookie,
          maintainState: true,
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          leading: const Icon(Icons.language_rounded),
          title: const Text('网页登录'),
          subtitle: Text(
            _checking
                ? '正在检查登录状态…'
                : _loggedIn
                    ? _accountLabel
                    : '登录后删除收藏可同步到 Bangumi',
          ),
          children: [
            const SizedBox(height: 8),
            const Text(
              'Bangumi 未提供删除收藏的开放接口，只能通过网页端删除。'
              '这里的账号密码仅用于向 bgm.tv 换取登录凭证，凭证保存在本机。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            if (_loggedIn) _loggedInView() else _loginForm(),
            const SizedBox(height: 20),
            Divider(height: 1, color: Theme.of(context).dividerColor),
            // 滑块往下沉一点，避免和分隔线贴在一起。
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SettingsSliderTile(
                leading: Icons.timer_outlined,
                title: const Text('检测间隔'),
                description: const Text('进页面时检查登录状态的间隔，超过就重新校验'),
                value: _intervalHours.toDouble(),
                min: 1,
                max: 24,
                divisions: 23,
                valueLabel: '$_intervalHours 小时',
                onChanged: (value) {
                  setState(() => _intervalHours = value.round());
                  GStorage.putSetting(
                    SettingsKeys.bangumiWebValidateIntervalHours,
                    _intervalHours,
                  );
                },
              ),
            ),
          ],
        ),
      );

  Widget _loggedInView() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle_rounded, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _loginLabel,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [
              TextButton.icon(
                onPressed: _busy ? null : _validate,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重新检查'),
              ),
              StateActionButton.tonal(
                onPressed: _busy ? null : _logout,
                text: '退出登录',
                icon: Icons.logout_rounded,
              ),
            ],
          ),
        ],
      );

  Widget _loginForm() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: _fieldHeight,
            child: TextField(
              controller: _emailController,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.emailAddress,
              decoration: _fieldDecoration(labelText: '邮箱 / 用户名'),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: _fieldHeight,
            child: TextField(
              controller: _passwordController,
              enabled: !_busy,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: _fieldDecoration(
                labelText: '密码',
                suffixIcon: IconButton(
                  tooltip: _obscure ? '显示密码' : '隐藏密码',
                  onPressed: () => setState(() => _obscure = !_obscure),
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(_obscure
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 用 IntrinsicHeight 让这一行的高度由左侧输入框的真实高度决定，
          // 右侧图片框只负责撑满同一高度；左侧不再被外面写死的 SizedBox 约束，
          // 也不再自己定高，两边就严格等高。
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: TextField(
                    controller: _captchaController,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    onSubmitted: (_) => _login(),
                    decoration: _fieldDecoration(labelText: '验证码'),
                  ),
                ),
                const SizedBox(width: 12),
                _captchaBox(),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // 提示文字对齐到左侧「验证码」输入框的正中，右侧留出图片框同宽的占位。
          Row(
            children: [
              Expanded(
                child: Center(
                  child: Text(
                    _captcha == null ? '请先点右侧获取验证码' : '看不清就点图片换一张',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const SizedBox(width: 120),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 16),
          // 「获取验证码」按钮已去掉：点右侧验证码框即可获取/刷新，功能重复。
          Align(
            alignment: Alignment.centerRight,
            child: StateActionButton.tonal(
              onPressed: _busy ? null : _login,
              text: _loggingIn ? '正在登录…' : '登录并保存',
              icon: Icons.login_rounded,
            ),
          ),
        ],
      );

  Widget _captchaBox() {
    final captcha = _captcha;
    final hasImage = captcha != null && captcha.image.isNotEmpty;
    // 高度完全交给外层 IntrinsicHeight + Row(stretch)：这里不写 width/height 之外的尺寸，
    // 图片用 BoxDecoration.image 绘制（DecorationImage 不参与固有尺寸计算），
    // 所以不会把 Row 的固有高度顶大，也就不会出现「量到无穷大 -> 白屏」。
    // 之前用 Image.memory + double.infinity 就是因为参与固有测量而整页白屏。
    return InkWell(
      onTap: _busy ? null : _refreshCaptcha,
      borderRadius: _fieldRadius,
      child: Container(
        width: 120,
        decoration: BoxDecoration(
          // 不留白：图片铺满整框，圆角由 BoxDecoration 自己裁剪。
          image: hasImage
              ? DecorationImage(
                  image: MemoryImage(captcha.image),
                  fit: BoxFit.cover,
                )
              : null,
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: _fieldRadius,
        ),
        child: hasImage
            ? null
            : Center(
                child: _loadingCaptcha
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('点此获取', style: TextStyle(fontSize: 12)),
              ),
      ),
    );
  }
}
