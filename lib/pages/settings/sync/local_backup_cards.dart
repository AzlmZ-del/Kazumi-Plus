import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/bean/widget/tonal_card.dart';
import 'package:kazumi/pages/settings/sync/sync_settings_widgets.dart';
import 'package:kazumi/services/backup/local_backup_service.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 「多设备同步」页里的【本地备份路径】卡：负责填目录、显示当前目录。
///
/// 目录既能手打完整路径，也能点「选择目录」开系统选择器回填 —— 两者最终
/// 都走 `LocalBackupService` 的同一套落地流程（建目录 + 试写 + 存设置），
/// 所以填错了会立刻在「保存」时被挡下来，而不是等到备份时才发现。
///
/// 与【同步服务器】卡的分工一致——这里只解决「备份到哪儿」，
/// 「备份什么」和「什么时候备份」都在下面的【启用本地备份】卡里。
class LocalBackupDirectoryCard extends StatefulWidget {
  const LocalBackupDirectoryCard({
    super.key,
    required this.onDirectoryChanged,
  });

  /// 目录变化后通知父级重建：下面的【启用本地备份】卡要靠它决定按钮可用态。
  final VoidCallback onDirectoryChanged;

  @override
  State<LocalBackupDirectoryCard> createState() =>
      _LocalBackupDirectoryCardState();
}

class _LocalBackupDirectoryCardState extends State<LocalBackupDirectoryCard> {
  /// 输入框与动作按钮的高度，与「同步服务器」卡的 `_fieldHeight` 同值。
  static const double _fieldHeight = 48;

  /// 动作按钮的左右内缩，对齐卡内 `Divider(indent: 16)`，
  /// 与「同步服务器」卡的 `_buttonInset` 同值。
  static const double _buttonInset = 16;

  final LocalBackupService _service = inject<LocalBackupService>();

  /// 目录输入框的内容。既可手打，也可由系统选择器回填。
  final TextEditingController _pathController = TextEditingController();

  /// 展开态。null 时退回 `initiallyExpanded`（未选目录就展开）。
  bool? _expanded;

  /// 原生目录选择器正在前台。
  bool _selecting = false;

  /// 正在把手填的路径落盘（建目录 + 试写）。
  bool _saving = false;

  bool get _busy => _selecting || _saving;

  final ExpansibleController _tileController = ExpansibleController();

  @override
  void initState() {
    super.initState();
    _pathController.text = _service.directory;
  }

  @override
  void dispose() {
    _tileController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  /// 选完目录就收起展开区：这块本来就是「换目录」用的，和【同步服务器】卡一个习惯。
  void _collapseAfterSaved() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _tileController.collapse();
      setState(() => _expanded = false);
    });
  }

  Future<void> _select() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _selecting = true);
    try {
      final selected = await _service.selectDirectory();
      if (!mounted) return;
      if (selected == null) return; // 用户取消，不算失败，也不弹提示。
      _pathController.text = selected;
      KazumiDialog.showToast(message: '备份目录已更新');
      widget.onDirectoryChanged();
      _collapseAfterSaved();
    } catch (e) {
      KazumiLogger().w('LocalBackup: select directory failed', error: e);
      if (!mounted) return;
      KazumiDialog.showToast(message: '$e');
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  /// 把手打的路径落盘。与 [_select] 的区别只在路径来源。
  Future<void> _save() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _saving = true);
    try {
      final saved = await _service.setDirectory(_pathController.text);
      if (!mounted) return;
      _pathController.text = saved;
      KazumiDialog.showToast(message: '备份目录已更新');
      widget.onDirectoryChanged();
      _collapseAfterSaved();
    } catch (e) {
      KazumiLogger().w('LocalBackup: save directory failed', error: e);
      if (!mounted) return;
      KazumiDialog.showToast(message: '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final directory = _service.directory;
    final configured = directory.isNotEmpty;
    final expanded = _expanded ?? !configured;

    return TonalCard(
      elevation: kSyncCardElevation,
      child: ExpansionTile(
        controller: _tileController,
        initiallyExpanded: !configured,
        maintainState: true,
        shape: const Border(),
        collapsedShape: const Border(),
        minTileHeight: kSyncCardTileHeight,
        tilePadding: const EdgeInsets.symmetric(horizontal: 20),
        childrenPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        leading: Icon(Icons.folder_rounded, color: colors.onSurfaceVariant),
        title: const SyncCardTitle('本地备份路径'),
        subtitle: SyncCardSubtitle(
          configured ? directory : '尚未选择备份目录',
        ),
        trailing: SyncExpandChevron(expanded: expanded),
        onExpansionChanged: (value) => setState(() => _expanded = value),
        children: [
          Column(
            spacing: 20,
            children: [
              // 与【同步服务器】卡一致：输入框整行、固定 48 高、M3 描边。
              // 可直接手打路径，也可以点下面的按钮开系统选择器回填。
              SizedBox(
                height: _fieldHeight,
                child: TextField(
                  controller: _pathController,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _save(),
                  style: Theme.of(context).textTheme.bodyMedium,
                  decoration: const InputDecoration(
                    labelText: '备份目录',
                    hintText: '点下方按钮选择，或直接填写完整路径',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              // 与【网页登录】卡的按钮组完全一致：两颗等宽平分整行、
              // 等高 `kSyncBundledButtonHeight`、左右内缩 16dp 对齐卡内分隔线，
              // 忙时只禁用不改文案（文字换了宽度会跳，`reserveText` 那套也不再需要）。
              // 用 `Expanded` + `SizedBox(height:)` 而不是 stretch，理由同那张卡：
              // `FilledButton` 内部的 `_InputPadding` 会把约束放松，必须靠 `Expanded`
              // 给紧宽度。
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: _buttonInset),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: kSyncBundledButtonHeight,
                        child: StateActionButton.tonal(
                          onPressed: _busy ? null : _save,
                          text: '保存目录',
                          icon: Icons.check_rounded,
                          style: syncBundledButtonStyle(context),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: kSyncBundledButtonHeight,
                        child: StateActionButton.tonal(
                          onPressed: _busy ? null : _select,
                          text: '选择目录',
                          icon: Icons.folder_open_rounded,
                          style: syncBundledButtonStyle(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 「多设备同步」页里的【启用本地备份】卡：总开关 + 四项内容开关 + 备份/恢复按钮。
///
/// 结构与【启用 WebDAV】卡同构：头部是总开关，展开区先列要备份的内容，
/// 再给动作按钮。区别只在总开关控制的是「本地备份是否启用」，
/// 而且没有网络可连，所以只有「选好目录」这一个前置条件。
class LocalBackupSettingsCard extends StatefulWidget {
  const LocalBackupSettingsCard({super.key});

  @override
  State<LocalBackupSettingsCard> createState() =>
      _LocalBackupSettingsCardState();
}

class _LocalBackupSettingsCardState extends State<LocalBackupSettingsCard> {
  /// 动作按钮的左右内缩，对齐卡内 `Divider(indent: 16)`。
  static const double _buttonInset = 16;

  final LocalBackupService _service = inject<LocalBackupService>();

  /// 展开态。进页面一律折叠，页内拨开关时才联动（见 `_toggleEnabled`）。
  bool _expanded = false;

  /// 拨开关要联动展开/折叠，得拿到 `ExpansionTile` 的控制器。
  final ExpansibleController _tileController = ExpansibleController();

  /// 正在跑的动作：`'backup'` / `'restore'` / `'other'` / null。
  ///
  /// `'other'` 是拨总开关这类没有独立按钮的页级动作，此时所有按钮进忙碌态。
  String? _busyAction;

  bool get _busy => _busyAction != null;

  @override
  void dispose() {
    _tileController.dispose();
    super.dispose();
  }

  Future<void> _run({
    required String busyKey,
    required String startMessage,
    required String successPrefix,
    required Future<String> Function() action,
  }) async {
    if (_busy) return;
    setState(() => _busyAction = busyKey);
    KazumiDialog.showToast(message: startMessage);
    try {
      final items = await action();
      if (!mounted) return;
      KazumiDialog.showToast(message: '$successPrefix：$items');
    } catch (e) {
      KazumiLogger().w('LocalBackup: $busyKey failed', error: e);
      if (!mounted) return;
      KazumiDialog.showToast(message: '$e');
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  Future<void> _backup() => _run(
    busyKey: 'backup',
    startMessage: '正在备份到本地…',
    successPrefix: '已备份',
    action: _service.backup,
  );

  Future<void> _restore() => _run(
    busyKey: 'restore',
    startMessage: '正在从本地恢复…',
    successPrefix: '已恢复',
    action: _service.restore,
  );

  Future<void> _toggle(SettingKey<bool> key, bool value) async {
    await GStorage.putSetting(key, value);
    if (mounted) setState(() {});
  }

  /// 拨总开关时同步展开态：开启就展开、关闭就折叠。
  ///
  /// 与【启用 WebDAV】卡同款：`_expanded` 由 `onExpansionChanged` 统一更新，
  /// 这里只驱动控制器，免得两处赋值打架。
  Future<void> _toggleEnabled(bool value) async {
    if (_busy) return;
    if (value) {
      _tileController.expand();
    } else {
      _tileController.collapse();
    }
    setState(() => _busyAction = 'other');
    try {
      await _service.setEnabled(value);
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final secondary = colors.onSurfaceVariant;
    final configured = _service.directory.isNotEmpty;
    final enabled = _service.enabled;
    final followWebDav = _service.followWebDav;
    final history = _service.historySelected;
    final collect = _service.collectSelected;
    final shield = _service.shieldSelected;
    final credentials = _service.credentialsSelected;
    // 没选目录时整卡置灰：备份到哪都还不知道，开关拨了也没意义。
    final dimmed = colors.onSurface.withValues(alpha: 0.38);
    final foreground = configured ? colors.onSurface : dimmed;
    final subtitleColor = configured ? secondary : dimmed;
    final subtitle = configured
        ? (enabled
              ? (followWebDav ? '已开启，备份选项跟随 WebDAV' : '已开启，请选择要备份内容')
              : '开启后选择要备份的内容')
        : '请先选择备份目录';
    // 总开关开着、选好目录、且没有动作在跑，才能动。
    final canAct = configured && enabled && !_busy;

    return TonalCard(
      elevation: kSyncCardElevation,
      child: ExpansionTile(
        controller: _tileController,
        initiallyExpanded: _expanded,
        maintainState: true,
        shape: const Border(),
        collapsedShape: const Border(),
        minTileHeight: kSyncCardTileHeight,
        tilePadding: const EdgeInsets.symmetric(horizontal: 20),
        childrenPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        leading: Icon(
          Icons.settings_backup_restore_rounded,
          color: subtitleColor,
        ),
        title: SyncCardTitle('启用本地备份', color: foreground),
        subtitle: SyncCardSubtitle(subtitle, color: subtitleColor),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 备份中也允许收起：收起来只是把内容区藏了，动作照旧在跑。
            // 开关本身仍受 `_busy` 限制。
            Switch(
              value: enabled,
              onChanged: configured && !_busy ? _toggleEnabled : null,
            ),
            SyncExpandChevron(expanded: _expanded, color: subtitleColor),
          ],
        ),
        onExpansionChanged: (value) => setState(() => _expanded = value),
        children: [
          // 「同步选项」放在分割线上方：它是「怎么决定备份哪几项」的
          // 选择器，逻辑上属于整张卡的前置，而不是下面四项中的一个。
          SwitchListTile(
            secondary: Icon(Icons.cloud_sync_rounded, size: 24, color: secondary),
            title: const Text('同步选项'),
            subtitle: Text(
              '让备份选项与云端同步',
              style: syncSwitchSubtitleStyle(context),
            ),
            value: followWebDav,
            onChanged: enabled && !_busy
                ? (value) => _toggle(SettingsKeys.localBackupFollowWebDav, value)
                : null,
          ),
          // 跟随云端时四项由【启用 WebDAV】那边决定，这里全部藏起来：
          // 分割线也一起去掉，否则会剩一条悬空的线。
          if (!followWebDav) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            SwitchListTile(
              secondary: Icon(Icons.history_rounded, size: 24, color: secondary),
              title: const Text('观看记录'),
              subtitle: Text(
                '备份播放进度与历史记录',
                style: syncSwitchSubtitleStyle(context),
              ),
              value: history,
              onChanged: enabled && !_busy
                  ? (value) =>
                      _toggle(SettingsKeys.localBackupEnableHistory, value)
                  : null,
            ),
            SwitchListTile(
              secondary: Icon(
                Icons.favorite_rounded,
                size: 24,
                color: secondary,
              ),
              title: const Text('收藏列表'),
              subtitle: Text(
                '备份所有追番分类与收藏状态',
                style: syncSwitchSubtitleStyle(context),
              ),
              value: collect,
              onChanged: enabled && !_busy
                  ? (value) =>
                      _toggle(SettingsKeys.localBackupEnableCollect, value)
                  : null,
            ),
            SwitchListTile(
              secondary: Icon(
                Icons.filter_alt_rounded,
                size: 24,
                color: secondary,
              ),
              title: const Text('弹幕屏蔽词'),
              subtitle: Text(
                '备份关键词与正则表达式规则',
                style: syncSwitchSubtitleStyle(context),
              ),
              value: shield,
              onChanged: enabled && !_busy
                  ? (value) => _toggle(
                      SettingsKeys.localBackupEnableDanmakuShield,
                      value,
                    )
                  : null,
            ),
            SwitchListTile(
              secondary: Icon(Icons.key_rounded, size: 24, color: secondary),
              title: const Text('用户凭据'),
              subtitle: Text(
                '备份 Bangumi 与服务器账号信息（AES 加密存储）',
                style: syncSwitchSubtitleStyle(context),
              ),
              value: credentials,
              onChanged: enabled && !_busy
                  ? (value) => _toggle(
                      SettingsKeys.localBackupEnableCredentials,
                      value,
                    )
                  : null,
            ),
          ],
          // 总开关关闭时不显示按钮区：开关都禁用了，按钮留着也没法点。
          if (enabled)
            Padding(
              // 横向在 childrenPadding 的 12dp 之上再缩 16dp，对齐卡内
              // `Divider(indent: 16, endIndent: 16)`；顶部 10dp 与开关列表拉开。
              padding: const EdgeInsets.symmetric(horizontal: _buttonInset),
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 10,
                  children: [
                    SyncActionButton(
                      onPressed: canAct ? _backup : null,
                      text: _busyAction == 'backup' || _busyAction == 'other'
                          ? '请稍候…'
                          : '立即备份到本地',
                      icon: Icons.save_alt_rounded,
                    ),
                    SyncActionButton(
                      onPressed: canAct ? _restore : null,
                      text: _busyAction == 'restore' || _busyAction == 'other'
                          ? '请稍候…'
                          : '从本地恢复数据',
                      icon: Icons.settings_backup_restore_rounded,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
