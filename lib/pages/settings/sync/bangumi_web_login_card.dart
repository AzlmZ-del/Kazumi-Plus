import 'package:flutter/material.dart';

import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/bean/widget/tonal_card.dart';
import 'package:kazumi/pages/settings/sync/sync_settings_widgets.dart';
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

  /// cookie 还在本地、但服务端判定已失效。此时副标题给「Cookie 失效，请重新登录」，
  /// 与「从没登录过」区分开——后者是「登录后删除收藏可同步到 Bangumi」。
  bool _expired = false;

  /// 校验请求本身出错（断网 / 超时）。这时**不能**断言 cookie 失效，
  /// 否则用户会以为要重新登录，白填一次验证码。
  bool _checkFailed = false;
  String? _error;

  /// Bangumi 昵称。网页登录只拿得到 UID，昵称要拿 Access Token 打一次
  /// `/v0/me`；拿不到就退回 UID，不影响登录本身。
  String _nickname = '';

  /// 检测登录状态的间隔（小时），1~24，默认 6。
  late int _intervalHours;

  /// 卡片展开态，仅用于驱动右侧箭头。null 时退回 `initiallyExpanded`。
  bool? _expanded;

  @override
  void initState() {
    super.initState();
    // 「登录并保存」会把账号密码记下来，下次进来直接回填，不用再敲一遍。
    _emailController.text = _session.savedEmail;
    _passwordController.text = _session.savedPassword;
    _intervalHours = GStorage.getSetting(
      SettingsKeys.bangumiWebValidateIntervalHours,
    ).clamp(1, 24);
    if (_session.hasStoredCookie) {
      // 昵称先同步读本地缓存，首帧就是「昵称 · UID」，不会先闪一下「已登录」。
      // 真正的更新在下面 `_loadNickname()` 里做，界面不会跳。
      _nickname = _session.savedNickname;
      // 缓存窗口内直接用上次结论，省掉进页面那次 /subject/1 请求；
      // 没有缓存（从没校验过 / 已过期）才真去查。
      final cached = _session.cachedValidation;
      if (cached != null) {
        _loggedIn = cached;
        _expired = !cached;
        if (cached) _loadNickname();
      } else {
        _validate();
      }
    }
    // 验证码不在这里预取：卡片默认收起，`_ensureCaptcha` 会自己判定
    // 「折叠就不请求」，等用户真的展开（`onExpansionChanged`）时再拉。
  }

  /// 验证码按需加载：没有图、没在加载、且不在登录中时才发请求。
  ///
  /// 验证码与登录必须共用同一条 cookie 会话（见 `fetchCaptcha` 的注释），
  /// 所以不能提前缓存一张反复用，每次展开都重新抓。
  void _ensureCaptcha() {
    if (!mounted) return;
    if (_captcha != null || _loadingCaptcha || _loggingIn || _checking) return;
    if (_loggedIn) return;
    // 折叠状态下表单根本看不见，别白花两条请求。
    if (!_isExpanded) return;
    _refreshCaptcha();
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
      _checkFailed = false;
    });
    try {
      final ok = await _session.validate();
      KazumiLogger().i('BangumiWebUI: session validate -> $ok');
      if (mounted) {
        setState(() {
          _loggedIn = ok;
          // cookie 还在但校验失败 = 过期；从没登录过的情况根本不会走到这里。
          _expired = !ok && _session.hasStoredCookie;
        });
      }
      if (ok) await _loadNickname();
    } catch (e, stackTrace) {
      KazumiLogger().w(
        'BangumiWebUI: session validate threw',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        // 请求本身失败（断网 / 超时）不代表 cookie 失效，只标记「检查失败」，
        // 保留上一次的登录态，避免误报「请重新登录」。
        setState(() => _checkFailed = true);
      }
    } finally {
      if (mounted) {
        setState(() => _checking = false);
        // 校验完才发现 cookie 过期时，表单这时才露出来，补一张验证码。
        if (!_loggedIn) _ensureCaptcha();
      }
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
      if (name.isEmpty) return;
      // 落盘一份，下次进页面首帧就能直接显示，不用等这次请求。
      await _session.saveNickname(name);
      if (mounted) setState(() => _nickname = name);
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
          _expired = false;
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
      _expired = false;
      _nickname = '';
      _captcha = null;
      _captchaController.clear();
      // 退出的是登录态，不是「已保存的账号密码」——两回事，输入框保持原样。
    });
    KazumiDialog.showToast(message: '已退出网页登录');
    // 退出后表单重新露出来，同样先把验证码摆好。
    _ensureCaptcha();
  }

  static String _describe(Object error) {
    if (error is BangumiWebLoginException) {
      return error.message;
    }
    return '网络请求失败，请检查网络后重试';
  }

  bool get _busy => _loggingIn || _loadingCaptcha || _checking;

  /// 三个输入框的可用性：验证码在后台加载时**不能**把它们一起锁掉。
  /// 卡片一展开就自动抓图，若沿用 `!_busy`，输入框会在用户刚要点进去的
  /// 那一刻变成 disabled——焦点丢失、键盘收起，看着像「点了没反应」。
  bool get _formEnabled => !_loggingIn && !_checking;

  /// 当前是否展开。`_expanded` 只有用户手动点过才有值，
  /// 首帧前一律按 `initiallyExpanded`（恒为 false）推算。
  bool get _isExpanded => _expanded ?? false;

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

  /// 按钮组与下方分隔线的左右内缩一致：分隔线是 `indent: 16 / endIndent: 16`。
  static const double _buttonInset = 16;

  InputDecoration _fieldDecoration({
    required String labelText,
    Widget? suffixIcon,
  }) => InputDecoration(
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
    elevation: kSyncCardElevation,
    child: ExpansionTile(
      // 一律默认收起，与是否登录无关：这张卡平时只是「看一眼登录状态」，
      // 表单摊开会把页面挤得很长。要看表单就点一下展开。
      initiallyExpanded: false,
      maintainState: true,
      shape: const Border(),
      collapsedShape: const Border(),
      trailing: SyncExpandChevron(expanded: _isExpanded),
      onExpansionChanged: (value) {
        setState(() => _expanded = value);
        // 每次展开都补一张：与网页端一致，表单露出来就能直接填。
        // 已有图时不重复请求，由 `_ensureCaptcha` 自己判。
        if (value) _ensureCaptcha();
      },
      minTileHeight: kSyncCardTileHeight,
      tilePadding: const EdgeInsets.symmetric(horizontal: 20),
      // 展开区四边统一 12dp（与其余五张卡一致）。
      childrenPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      leading: const Icon(Icons.language_rounded),
      title: const SyncCardTitle('网页登录'),
      subtitle: SyncCardSubtitle(
        _checking
            ? '正在检查登录状态…'
            : _loggedIn
            ? _accountLabel
            : _expired
            ? 'Cookie 失效，请重新登录'
            : _checkFailed
            ? '登录状态检查失败，可稍后重试'
            : '登录后删除收藏可同步到 Bangumi',
      ),
      children: [
        // 顶部间距统一由 `childrenPadding` 的 12dp 提供，这里不再塞占位。
        // 原来那两行「Bangumi 未提供删除收藏的开放接口…」的说明已按用户要求删除。
        if (_loggedIn) _loggedInView() else _loginForm(),
        const SizedBox(height: 20),
        const Divider(height: 1, indent: 16, endIndent: 16),
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
      // 按钮组的左右边缘统一对齐下方那条分隔线：`Divider(indent: 16, endIndent: 16)`
      // 是从 `childrenPadding` 的 12dp 再往里缩 16dp，所以这里补上同样的 16dp。
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: _buttonInset),
        // 两个按钮等宽平分整行、等高 `kSyncBundledButtonHeight`。
        // 用 `Expanded` + `SizedBox(height:)` 而不是 `stretch`：`FilledButton` 内部的
        // `_InputPadding` 会把约束放松成「至多父级宽度」，只靠 stretch 拿不到满宽，
        // 必须由 `Expanded` 给紧宽度、`SizedBox` 只钉高度。
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: kSyncBundledButtonHeight,
                child: StateActionButton.tonal(
                  onPressed: _busy ? null : _validate,
                  text: '重新检查',
                  icon: Icons.refresh_rounded,
                  style: syncBundledButtonStyle(context),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: kSyncBundledButtonHeight,
                child: StateActionButton.tonal(
                  onPressed: _busy ? null : _logout,
                  text: '退出登录',
                  icon: Icons.logout_rounded,
                  style: syncBundledButtonStyle(context),
                ),
              ),
            ),
          ],
        ),
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
          enabled: _formEnabled,
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
          enabled: _formEnabled,
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
              icon: Icon(
                _obscure
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
              ),
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
                enabled: _formEnabled,
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
                _captcha == null ? '正在获取验证码…' : '看不清就点图片换一张',
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
      //
      // 与已登录态的「重新检查 / 退出登录」保持同一规格：左右边缘对齐下方分隔线，
      // 宽度只占半行。原来靠 `Align(centerRight)` 拿右边缘，宽度是内容自适应；
      // 这里改成「左侧等宽占位 + 右侧 Expanded」，右边缘仍贴在分隔线右端，
      // 但宽度固定为半行（扣掉中间 12dp 间距），与「退出登录」那颗完全同宽。
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: _buttonInset),
        child: Row(
          children: [
            const Expanded(child: SizedBox.shrink()),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: kSyncBundledButtonHeight,
                child: StateActionButton.tonal(
                  onPressed: _busy ? null : _login,
                  text: _loggingIn ? '正在登录…' : '登录并保存',
                  icon: Icons.login_rounded,
                  style: syncBundledButtonStyle(context),
                ),
              ),
            ),
          ],
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
