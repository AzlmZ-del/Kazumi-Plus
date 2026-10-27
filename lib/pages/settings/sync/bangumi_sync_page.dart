import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/bean/dialog/kazumi_toast.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/bean/widget/tonal_card.dart';
import 'package:kazumi/modules/bangumi/sync_priority.dart';
import 'package:kazumi/pages/settings/sync/bangumi_web_login_card.dart';
import 'package:kazumi/pages/settings/sync/sync_settings_widgets.dart';
import 'package:kazumi/services/backup/local_backup_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/bangumi_sync_service.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:kazumi/services/logging/logger.dart';

enum _BangumiAction { verify, connect, sync }

class BangumiSyncPage extends StatefulWidget {
  const BangumiSyncPage({super.key});

  @override
  State<BangumiSyncPage> createState() => _BangumiSyncPageState();
}

class _BangumiSyncPageState extends State<BangumiSyncPage> {
  /// Access Token 输入框高度，与「网页登录」卡片里的输入框统一为 48。
  static const double _tokenFieldHeight = 48;

  /// 按钮组与卡片内分隔线的左右内缩一致：分隔线是 `indent: 16 / endIndent: 16`。
  /// 与「网页登录」卡的同名常量 `_buttonInset` 取同一个值。
  static const double _buttonInset = 16;

  final _tokenController = TextEditingController();
  final _bangumi = BangumiSyncService();
  bool _passwordVisible = false;
  _BangumiAction? _action;
  String? _tokenError;
  String? _message;
  bool _failed = false;

  /// 两个可折叠卡片的展开态，仅用于驱动右侧箭头（箭头要跟着转）。
  /// 为 null 时退回 `initiallyExpanded` 的默认值。
  bool? _accountExpanded;
  bool? _prefsExpanded;

  /// 「Bangumi 账号」卡面板展开/收起的真控制器：保存成功后的自动收起
  /// 必须走 `collapse()`，只改 `_accountExpanded` 布尔只会转箭头、
  /// 面板纹丝不动（`ExpansionTile` 的展开动画由控制器驱动）。
  final ExpansibleController _accountController = ExpansibleController();

  /// 「自动同步追番」卡片展开态：展开后露出「立即同步追番」按钮。
  bool _autoExpanded = false;

  bool get _busy => _action != null || _bangumi.isConnecting;

  @override
  void initState() {
    super.initState();
    _tokenController.text = GStorage.getSetting(
      SettingsKeys.bangumiAccessToken,
    );
  }

  @override
  void dispose() {
    _accountController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _saveToken() async {
    if (_busy) return;
    if (_tokenController.text.trim().isEmpty) {
      setState(() => _tokenError = '请填写 Access Token');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _action = _BangumiAction.verify;
      _tokenError = null;
      _message = null;
      _failed = false;
    });
    try {
      await _bangumi.saveToken(_tokenController.text);
      if (mounted) {
        // 保存成功后的「已连接 用户名」不再在输入框下重复展示——
        // 卡片头部的副标题（「已连接 · 用户名」）刷新后就有同样的信息。
        _tokenController.text = GStorage.getSetting(
          SettingsKeys.bangumiAccessToken,
        );
      }
      // Token 验证并保存成功 → 自动备份一次凭据（用户凭据开关开启时）。
      // fire-and-forget：面板收起不等云端上传，失败由服务层弹提示。
      unawaited(WebDav().autoBackupCredentialsAfterSave());
      unawaited(inject<LocalBackupService>().autoBackupCredentialsAfterSave());
      // 配好就收起来（与「同步服务器」卡同款）：挪到本帧结束后执行，
      // 避免被 toast/状态刷新触发的 rebuild 盖回去。
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _accountController.collapse();
          setState(() => _accountExpanded = false);
        });
      }
    } catch (e) {
      if (mounted) {
        _tokenError = '${BangumiSyncService.describeError(e)}。修改未保存';
      }
    } finally {
      if (mounted) setState(() => _action = null);
    }
  }

  Future<void> _connect(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _action = _BangumiAction.connect;
      _message = null;
      _failed = false;
    });
    try {
      await action();
    } catch (e) {
      _message = BangumiSyncService.describeError(e);
      _failed = true;
    } finally {
      if (mounted) setState(() => _action = null);
    }
  }

  Future<void> _getToken() async {
    bool opened;
    try {
      opened = await launchUrl(
        Uri.parse('https://next.bgm.tv/demo/access-token'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      setState(() => _tokenError = '无法打开浏览器，请稍后重试');
    }
  }

  /// 「立即同步追番」与 WebDAV 页三个同步按钮同款：开始、成功、失败都弹
  /// 胶囊提示（toast），不再往页面里塞常驻反馈条。
  ///
  /// 同步进度走「可更新胶囊」：整条胶囊只插一次，onProgress 每次回调只换
  /// 文字不重建（避免逐条重弹的闪烁），结束时换上成功/失败文案再收掉。
  Future<void> _sync() async {
    if (_busy) return;
    if (_tokenController.text.trim() !=
        GStorage.getSetting(SettingsKeys.bangumiAccessToken).trim()) {
      setState(() {
        _failed = true;
        _message = '账号信息已修改，请先验证并保存。';
      });
      return;
    }
    setState(() {
      _action = _BangumiAction.sync;
      _failed = false;
      _message = null;
    });
    KazumiDialog.showToast(message: '正在连接 Bangumi…');
    // 第一条进度回调到达前胶囊先不显示；连上后由 onProgress 常驻刷新。
    UpdatableKazumiToast? progressToast;
    try {
      await _bangumi.syncCollectibles(
        onProgress: (message, current, total) {
          progressToast ??= KazumiDialog.showPersistentToast(
            message: total > 0 ? '$message（$current/$total）' : message,
          );
          progressToast?.update(
            total > 0 ? '$message（$current/$total）' : message,
          );
        },
      );
      progressToast?.dismiss();
      progressToast = null;
      KazumiDialog.showToast(message: '追番状态已同步');
    } catch (e) {
      KazumiLogger().w('Bangumi settings sync failed', error: e);
      progressToast?.dismiss();
      progressToast = null;
      KazumiDialog.showToast(message: BangumiSyncService.describeError(e));
    } finally {
      progressToast?.dismiss();
      if (mounted) setState(() => _action = null);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _bangumi,
    builder: (context, _) {
      final configured = GStorage.getSetting(
        SettingsKeys.bangumiAccessToken,
      ).trim().isNotEmpty;
      final enabled = GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
      final priority = BangumiSyncPriority.fromValue(
        GStorage.getSetting(SettingsKeys.bangumiSyncPriority),
      );
      final showToast = GStorage.getSetting(
        SettingsKeys.bangumiImmediateSyncToastEnable,
      );
      // 常驻反馈条只剩错误兜底职责：开关切换（_connect）等失败的错误消息，
      // 以及服务层 lastError。同步操作本身已改走胶囊提示，见 `_sync`。
      final message =
          _message ?? (_tokenError == null ? _bangumi.lastError : null);
      return PopScope(
        canPop: !_busy,
        child: SettingsDetailScaffold(
          title: const Text('追番同步'),
          body: SyncPageBody(
            maxWidth: 720,
            spacing: 15,
            children: [
              const SyncPageIntro(
                icon: Icons.bookmarks_rounded,
                title: 'Bangumi',
                description: '同步想看、在看、看过等追番状态。',
              ),
              _accountCard(configured),
              const BangumiWebLoginCard(),
              _syncControls(configured, enabled),
              if (message != null)
                SyncFeedback(
                  message: message,
                  error: _failed || _bangumi.lastError != null,
                ),
              TonalCard(
                elevation: kSyncCardElevation,
                child: ExpansionTile(
                  shape: const Border(),
                  collapsedShape: const Border(),
                  leading: const Icon(Icons.tune_rounded),
                  title: const SyncCardTitle('同步偏好'),
                  subtitle: SyncCardSubtitle('状态冲突时：${priority.label}'),
                  trailing: SyncExpandChevron(
                    expanded: _prefsExpanded ?? false,
                  ),
                  onExpansionChanged: (value) =>
                      setState(() => _prefsExpanded = value),
                  minTileHeight: kSyncCardTileHeight,
                  tilePadding: const EdgeInsets.symmetric(horizontal: 20),
                  // 顶部缝隙统一由 `childrenPadding` 提供，六张卡一致。
                  // 里面的 `RadioListTile` 自带内边距，会比其他卡稍显宽松，
                  // 属 `ListTile` 固有行为，不再逐项抠。
                  childrenPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  children: [
                    RadioGroup<BangumiSyncPriority>(
                      groupValue: priority,
                      onChanged: (value) async {
                        if (value == null || _busy) return;
                        await GStorage.putSetting(
                          SettingsKeys.bangumiSyncPriority,
                          value.value,
                        );
                        if (mounted) setState(() {});
                      },
                      child: Column(
                        children: [
                          for (final option in BangumiSyncPriority.values)
                            RadioListTile<BangumiSyncPriority>(
                              value: option,
                              enabled: !_busy,
                              title: Text(switch (option) {
                                BangumiSyncPriority.localFirst => '以本机为准',
                                BangumiSyncPriority.bangumiFirst =>
                                  '以 Bangumi 为准',
                                BangumiSyncPriority.timeFirst => '保留最近更新',
                              }),
                              subtitle: Text(
                                switch (option) {
                                  BangumiSyncPriority.localFirst =>
                                    '用本机状态更新 Bangumi',
                                  BangumiSyncPriority.bangumiFirst =>
                                    '用 Bangumi 状态更新本机',
                                  BangumiSyncPriority.timeFirst =>
                                    '比较两边的更新时间',
                                },
                                // 与卡片头部副标题同款：12sp + 置灰，
                                // 盖掉 `ListTile` 默认的 14sp 同色。
                                style: syncSwitchSubtitleStyle(context),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    SwitchListTile(
                      title: const Text('同步结果提示'),
                      // 与卡片头部副标题同款：12sp + 置灰，
                      // 盖掉 `ListTile` 默认的 14sp 同色。
                      subtitle: Text(
                        '修改追番状态后显示同步结果',
                        style: syncSwitchSubtitleStyle(context),
                      ),
                      value: showToast,
                      onChanged: _busy
                          ? null
                          : (value) async {
                              await GStorage.putSetting(
                                SettingsKeys.bangumiImmediateSyncToastEnable,
                                value,
                              );
                              if (mounted) setState(() {});
                            },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  /// 「自动同步追番」卡片：头部是开关，展开后露出「立即同步追番」按钮。
  ///
  /// 结构和另外三张卡片一致（`TonalCard` + `ExpansionTile`），
  /// 高度由 `kSyncCardTileHeight` 钉成 72dp，四张卡片对齐。
  Widget _syncControls(bool configured, bool enabled) => TonalCard(
    elevation: kSyncCardElevation,
    child: ExpansionTile(
      shape: const Border(),
      collapsedShape: const Border(),
      maintainState: true,
      leading: const Icon(Icons.sync_rounded),
      title: const SyncCardTitle('自动同步追番'),
      subtitle: SyncCardSubtitle(
        configured ? '修改追番状态时同步到 Bangumi' : '请先连接 Bangumi 账号',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: enabled,
            onChanged: configured && !_busy
                ? (value) => _connect(() => _bangumi.setEnabled(value))
                : null,
          ),
          SyncExpandChevron(expanded: _autoExpanded),
        ],
      ),
      onExpansionChanged: (value) => setState(() => _autoExpanded = value),
      // 垂直 padding 留 0，高度交给 `minTileHeight` 钉在 72dp：
      // 加 4+4 会变成 80dp，和其余卡片不齐。
      minTileHeight: kSyncCardTileHeight,
      tilePadding: const EdgeInsets.symmetric(horizontal: 20),
      // 展开区四边统一 12dp（与其余五张卡一致）。
      childrenPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      // 展开区默认 `CrossAxisAlignment.center`（`expansion_tile.dart:689`），
      // `SyncActionButton` 自带 `Align(centerLeft)`、宽度由 `SizedBox` 钉死，
      // 这里用 stretch 只为了让外层占满、按钮靠左对齐。
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 按钮左右边缘对齐卡内 `Divider(indent: 16)`：从 childrenPadding 的
        // 12dp 再往里缩 16dp，高度由 `SyncActionButton` 钉在 40dp。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _buttonInset),
          child: SyncActionButton(
            onPressed: enabled && configured && !_busy ? _sync : null,
            text: _action == _BangumiAction.sync
                ? '正在同步追番…'
                : '立即同步追番',
            icon: Icons.sync_rounded,
          ),
        ),
      ],
    ),
  );

  Widget _accountCard(bool configured) => TonalCard(
    elevation: kSyncCardElevation,
    child: ExpansionTile(
      controller: _accountController,
      initiallyExpanded: !configured,
      maintainState: true,
      shape: const Border(),
      collapsedShape: const Border(),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 「测试连接」搬到这里，紧贴右侧箭头。
          // 只在已保存授权信息时出现——没有 token 就没有可测的连接。
          if (configured) ...[_testConnectButton(), const SizedBox(width: 2)],
          SyncExpandChevron(expanded: _accountExpanded ?? !configured),
        ],
      ),
      onExpansionChanged: (value) => setState(() => _accountExpanded = value),
      // 垂直 padding 留 0，高度交给 `minTileHeight` 钉在 72dp：
      // 加 4+4 会变成 80dp，和其余卡片不齐。
      minTileHeight: kSyncCardTileHeight,
      tilePadding: const EdgeInsets.symmetric(horizontal: 20),
      // 展开区四边统一 12dp（与其余五张卡一致）。
      childrenPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      leading: const Icon(Icons.account_circle_outlined),
      title: SyncCardTitle(configured ? 'Bangumi 账号' : '连接 Bangumi 账号'),
      // 连接状态（原来在卡片底部单独一行）并进副标题。
      subtitle: SyncCardSubtitle(
        _action == _BangumiAction.connect || _bangumi.isConnecting
            ? '正在连接…'
            : _bangumi.initialized
            ? '已连接 · ${_bangumi.username}'
            : configured
            ? '已保存授权信息'
            : '使用 Access Token 授权',
      ),
      children: [
        // 顶部间距统一由 `childrenPadding` 的 12dp 提供，这里不再塞占位。
        // 输入框本体固定 48 高，与「网页登录」卡片里的三个输入框保持一致。
        // 报错/提示文字排在框外（errorText 会把框撑高，所以这里只在无错误时锁高）。
        SizedBox(
          height: _tokenFieldHeight,
          child: TextField(
            controller: _tokenController,
            enabled: !_busy,
            obscureText: !_passwordVisible,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() {
              _tokenError = null;
            }),
            onSubmitted: (_) => _saveToken(),
            decoration: InputDecoration(
              labelText: 'Access Token',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _passwordVisible ? '隐藏授权码' : '显示授权码',
                onPressed: () =>
                    setState(() => _passwordVisible = !_passwordVisible),
                // 图标表示「当前状态」：密文时画斜杠眼（已隐藏），
                // 明文时画睁眼（已显示）。之前反着来，看着像状态标错了。
                icon: Icon(
                  _passwordVisible
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                ),
              ),
            ),
          ),
        ),
        // 输入框下只兜错误红字；「正在验证…」进度由「验证并保存」按钮的
        // 文案与置灰表达，不再重复展示。
        if (_tokenError != null) ...[
          const SizedBox(height: 6),
          Text(
            _tokenError!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
            maxLines: 5,
          ),
        ],
        const SizedBox(height: 12),
        // 按钮组的左右边缘与「网页登录」卡的分隔线对齐：那里是
        // `Divider(indent: 16, endIndent: 16)`，即从 `childrenPadding` 的 12dp
        // 再往里缩 16dp，所以这里补上同样的 `_buttonInset`。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _buttonInset),
          // 两颗按钮等宽平分整行、等高 `kSyncBundledButtonHeight`，与
          // 「网页登录」卡的「重新检查 / 退出登录」保持同一套规格：
          // `Expanded` 给紧宽度、`SizedBox` 只钉高度（`FilledButton` 内部的
          // `_InputPadding` 会放松约束，单靠 `stretch` 拿不到满宽）。
          // 左边那颗仍是 M3 默认的裸 `TextButton.icon`（无底色），
          // 但同样占半行，右边「验证并保存」才能与「退出登录」完全同宽。
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: kSyncBundledButtonHeight,
                  child: TextButton.icon(
                    onPressed: _busy ? null : _getToken,
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: const Text('获取授权码'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: kSyncBundledButtonHeight,
                  child: StateActionButton.tonal(
                    onPressed: _busy ? null : _saveToken,
                    text: _action == _BangumiAction.verify
                        ? '正在验证…'
                        : '验证并保存',
                    icon: Icons.check_rounded,
                    style: syncBundledButtonStyle(context),
                  ),
                ),
              ),
            ],
          ),
        ),
        // 「测试连接」已移到卡片头部的箭头左侧，这里不再重复一行状态文字。
      ],
    ),
  );

  /// 卡片头部的「测试连接」小按钮，样式沿用 `StateActionButton.tonal`
  /// 但压缩到 28dp 高、左右 8dp、12sp 字号，塞进 72dp 高的头部里不撑高。
  Widget _testConnectButton() {
    final label = _action == _BangumiAction.connect || _bangumi.isConnecting
        ? '连接中…'
        : _bangumi.lastError != null
        ? '重试连接'
        : '测试连接';
    return SizedBox(
      height: 28,
      child: StateActionButton.tonal(
        onPressed: _busy ? null : () => _connect(_bangumi.ping),
        text: label,
        style: syncHeaderButtonStyle(context),
      ),
    );
  }
}
