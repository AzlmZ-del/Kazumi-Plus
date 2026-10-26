import 'package:flutter/material.dart';

import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/bean/widget/tonal_card.dart';
import 'package:kazumi/pages/settings/sync/sync_settings_widgets.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';

/// 「多设备同步」页里的「同步服务器」折叠卡。
///
/// 早先这里是一个 `SettingsTile`，点进去跳到独立页面填表；改完还得再返回，
/// 反复切换页面的操作冗余。现在表单直接放在卡片展开区：
/// 未配置时默认展开，配好之后收起、只显示域名，要改再点开。
class WebDavServerCard extends StatefulWidget {
  const WebDavServerCard({super.key, required this.onConfigurationChanged});

  /// 配置保存成功后通知父级重建：`configured` / 域名 / 「启用 WebDAV」卡的
  /// 置灰状态都依赖它。
  final VoidCallback onConfigurationChanged;

  @override
  State<WebDavServerCard> createState() => _WebDavServerCardState();
}

class _WebDavServerCardState extends State<WebDavServerCard> {
  /// 输入框统一高度，与「追番同步」页保持一致。
  static const double _fieldHeight = 48;

  final _formKey = GlobalKey<FormState>();
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();

  bool _passwordVisible = false;

  /// 展开区里【保存并测试】正在跑。
  bool _busy = false;

  /// 展开态。null 时退回 `initiallyExpanded`（未配置就展开）。
  bool? _expanded;

  /// 头部【测试连接】的进度与失败原因都取自服务层（`WebDav.isPinging` /
  /// `WebDav.lastPingError`），不放组件本地 —— 测试要跑好几秒，
  /// 中途切走页面再回来，按钮仍要显示「测试中…」，跟 Bangumi 那颗一致。
  /// 服务层没有通知机制，所以测试结束时靠 `setState` 让本页重绘。
  bool get _testing => WebDav().isPinging;
  bool get _testFailed => WebDav().lastPingError != null;

  @override
  void initState() {
    super.initState();
    _url.text = GStorage.getSetting(SettingsKeys.webDavURL);
    _username.text = GStorage.getSetting(SettingsKeys.webDavUsername);
    _password.text = GStorage.getSetting(SettingsKeys.webDavPassword);
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _configured =>
      GStorage.getSetting(SettingsKeys.webDavURL).trim().isNotEmpty;

  /// 卡片头部【测试连接】：只 ping 已保存的服务器，**不保存表单内容**。
  ///
  /// 与【保存并测试】的分工：
  /// - 头部这颗：验证「当前已生效的配置」还通不通，失败**不关同步开关**；
  /// - 展开区那颗：把输入框里的新内容存下来再测，失败会 `setEnabled(false)`。
  ///
  /// 之所以分开，是因为头部按钮在折叠状态下也能点，那时候表单里的内容
  /// 可能正是半截改动，直接拿去覆盖已保存的配置太危险。
  Future<void> _testConnection() async {
    if (_testing || _busy) return;
    // 先起请求，服务层会在第一个 await 之前就把 isPinging 置 true，
    // 再 setState 重绘，按钮立刻变「测试中…」。
    final future = WebDav().testConnection();
    setState(() {});
    try {
      await future;
      if (!mounted) return;
      KazumiDialog.showToast(message: '连接正常');
    } catch (e) {
      KazumiLogger().w('WebDAV ping failed', error: e);
      if (!mounted) return;
      KazumiDialog.showToast(message: '连接失败，请检查服务器地址、账号和密码');
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _save() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _busy = true);
    try {
      await GStorage.putSetting(SettingsKeys.webDavURL, _url.text.trim());
      await GStorage.putSetting(
        SettingsKeys.webDavUsername,
        _username.text.trim(),
      );
      await GStorage.putSetting(SettingsKeys.webDavPassword, _password.text);
      await WebDav().init();
      if (!mounted) return;
      KazumiDialog.showToast(message: '连接成功，配置已保存');
      // 存好就收起来：展开区本来就是「改配置」用的，配完该让位给下面的开关。
      // 失败标记由 `WebDav.init()` 自己清（它成功了就把 lastPingError 置空），
      // 配置都换成新的了，旧结论自然作废。
      setState(() => _expanded = false);
      widget.onConfigurationChanged();
    } catch (e) {
      KazumiLogger().w('WebDAV configuration failed', error: e);
      await WebDav().setEnabled(false);
      if (!mounted) return;
      KazumiDialog.showToast(message: '连接失败，同步已关闭。请检查服务器地址、账号和密码后重试。');
      widget.onConfigurationChanged();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final configured = _configured;
    final url = GStorage.getSetting(SettingsKeys.webDavURL).trim();
    final host = Uri.tryParse(url)?.host;
    final expanded = _expanded ?? !configured;

    return TonalCard(
      elevation: kSyncCardElevation,
      child: ExpansionTile(
        // 未配置时直接展开，省掉一次「点开再填」；
        // 只在首帧读一次，之后由 `_expanded` 接管。
        initiallyExpanded: !configured,
        maintainState: true,
        shape: const Border(),
        collapsedShape: const Border(),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 与「Bangumi 账号」卡一致：测试按钮紧贴箭头左侧。
            // 只在已保存服务器地址时出现——没地址就没有可测的东西。
            if (configured) ...[_testButton(), const SizedBox(width: 2)],
            SyncExpandChevron(expanded: expanded),
          ],
        ),
        onExpansionChanged: (value) => setState(() => _expanded = value),
        minTileHeight: kSyncCardTileHeight,
        tilePadding: const EdgeInsets.symmetric(horizontal: 20),
        // 展开区四边统一 12dp（与其余五张卡一致）。
        childrenPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        leading: const Icon(Icons.dns_rounded),
        title: SyncCardTitle(configured ? '同步服务器' : '连接你的云盘'),
        // 四态与「Bangumi 账号」卡完全同构：
        // 连接中 → 已连接 · 主机名 → 已保存配置（未连通）→ 尚未配置。
        // 原来这里在已配置时直接显示域名，看不出到底连没连上。
        subtitle: SyncCardSubtitle(
          // `_busy` 是展开区【保存并测试】在跑，`_testing` 是头部【测试连接】；
          // 两者都在发请求，副标题统一显示「正在连接…」。
          _testing || _busy
              ? '正在连接…'
              : WebDav().initialized
              ? (host == null || host.isEmpty ? '已连接' : '已连接 · $host')
              : configured
              ? '已保存服务器地址'
              : '需要支持 WebDAV 的云盘或服务器',
        ),
        children: [
          Form(
            key: _formKey,
            child: Column(
              spacing: 20,
              children: [
                // 三个输入框统一固定 48 高，与「追番同步」页保持一致。
                // 报错文字由 InputDecoration 自带，会临时把框撑高，属正常现象。
                SizedBox(
                  height: _fieldHeight,
                  child: TextFormField(
                    controller: _url,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '服务器地址',
                      hintText: 'https://example.com/dav/',
                      isDense: true,
                      border: OutlineInputBorder(),
                      errorMaxLines: 3,
                    ),
                    validator: (value) {
                      final uri = Uri.tryParse(value?.trim() ?? '');
                      if (uri == null ||
                          !['http', 'https'].contains(uri.scheme) ||
                          uri.host.isEmpty) {
                        return '请输入完整的 http:// 或 https:// 地址';
                      }
                      return null;
                    },
                  ),
                ),
                SizedBox(
                  height: _fieldHeight,
                  child: TextFormField(
                    controller: _username,
                    enabled: !_busy,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '用户名',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(
                  height: _fieldHeight,
                  child: TextFormField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: !_passwordVisible,
                    autocorrect: false,
                    enableSuggestions: false,
                    onFieldSubmitted: (_) => _save(),
                    decoration: InputDecoration(
                      labelText: '密码或应用授权码',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: _passwordVisible ? '隐藏密码' : '显示密码',
                        onPressed: () => setState(
                          () => _passwordVisible = !_passwordVisible,
                        ),
                        // 与「追番同步」页一致：图标表示当前状态，
                        // 密文画斜杠眼、明文画睁眼。
                        icon: Icon(
                          _passwordVisible
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                        ),
                      ),
                    ),
                  ),
                ),
                SyncActionButton(
                  onPressed: _busy ? null : _save,
                  text: _busy ? '正在测试连接…' : '保存并测试',
                  icon: Icons.cloud_done_rounded,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 卡片头部的【测试连接】小按钮，样式与「Bangumi 账号」那颗完全一致：
  /// `StateActionButton.tonal` + `syncHeaderButtonStyle`，压到 32dp 高，
  /// 塞进 72dp 的头部里不会把它撑高。
  ///
  /// 文案三态与 Bangumi 那颗对齐：测试中 → 重试连接（上次失败）→ 测试连接。
  Widget _testButton() {
    final label = _testing
        ? '测试中…'
        : _testFailed
        ? '重试连接'
        : '测试连接';
    return SizedBox(
      height: 32,
      child: StateActionButton.tonal(
        onPressed: _testing || _busy ? null : _testConnection,
        text: label,
        style: syncHeaderButtonStyle(context),
      ),
    );
  }
}
