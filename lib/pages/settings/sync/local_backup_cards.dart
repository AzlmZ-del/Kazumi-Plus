import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
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

  /// 输入框焦点。拿到焦点时不再被外部改动回填覆盖，免得打字打到一半被换掉。
  final FocusNode _pathFocus = FocusNode();

  /// 上一次与服务层对齐过的目录，用来识别「别处改了目录」。
  String _syncedDirectory = '';

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
    _syncedDirectory = _service.directory;
    _pathController.text = _syncedDirectory;
    // 失焦后补一次回填：有焦点时 `_scheduleDirectorySync` 会跳过，用户打完字移开
    // 才轮到外部改动（在下面那张卡里选的目录）生效。
    _pathFocus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (_pathFocus.hasFocus) return;
    final current = _service.directory;
    if (current == _syncedDirectory) return;
    _syncedDirectory = current;
    _pathController.text = current;
  }

  @override
  void dispose() {
    _tileController.dispose();
    _pathFocus.removeListener(_onFocusChanged);
    _pathFocus.dispose();
    _pathController.dispose();
    super.dispose();
  }

  /// 目录在别处被改（比如从下面的【启用本地备份】卡里选了目录）时回填输入框。
  ///
  /// 改 controller 放到帧后执行：build 期间通知 `EditableText` 会让它在构建中
  /// setState。输入框有焦点时不回填，等失焦后再补（见 `_pathFocus` 的监听），
  /// 免得打断正在手打的路径。
  void _scheduleDirectorySync() {
    final current = _service.directory;
    if (current == _syncedDirectory) return;
    if (_pathFocus.hasFocus) return;
    // 用「上次已知目录为空」判断是不是首次选到目录：`_expanded` 在用户手动
    // 展开/收起后就不再是 null，靠它判断会在重进页面时误收起。
    final wasEmpty = _syncedDirectory.isEmpty;
    _syncedDirectory = current;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pathController.text = current;
      if (wasEmpty && current.isNotEmpty) {
        _tileController.collapse();
        setState(() => _expanded = false);
      }
    });
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
      _syncedDirectory = selected;
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
  ///
  /// 输入框为空时按「清除已设置的备份路径」处理，但要先二次确认：
  /// 清掉之后备份按钮就得多走一次选目录流程，误触成本比误保存高。
  Future<void> _save() async {
    if (_busy) return;
    if (_pathController.text.trim().isEmpty) {
      await _clearDirectory();
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _saving = true);
    try {
      final saved = await _service.setDirectory(_pathController.text);
      if (!mounted) return;
      _pathController.text = saved;
      _syncedDirectory = saved;
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

  /// 清除已设置的备份路径。
  ///
  /// 只清路径、不动总开关：总开关是「要不要自动备份」的意图，和「备份到哪儿」
  /// 是两件事，清路径顺手关掉开关会让人以为自己关过。备份文件本身也不删。
  Future<void> _clearDirectory() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_service.directory.isEmpty) {
      _pathController.clear();
      KazumiDialog.showToast(message: '当前没有设置备份目录');
      return;
    }
    final confirmed = await KazumiDialog.show<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.folder_off_rounded),
        title: const Text('清除备份路径？'),
        content: const Text('清除后需要重新选择目录才能备份。已经备份的文件不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除路径'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await _service.resetDirectory();
      if (!mounted) return;
      _pathController.clear();
      _syncedDirectory = '';
      KazumiDialog.showToast(message: '备份路径已清除');
      widget.onDirectoryChanged();
    } catch (e) {
      KazumiLogger().w('LocalBackup: clear directory failed', error: e);
      if (!mounted) return;
      KazumiDialog.showToast(message: '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _scheduleDirectorySync();
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
                  focusNode: _pathFocus,
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
  const LocalBackupSettingsCard({super.key, this.onDirectoryChanged});

  /// 本卡替用户选了备份目录（无目录时点备份会先选目录）后，通知页面重建
  /// 上面的【本地备份路径】卡，把新目录回填到输入框。
  final VoidCallback? onDirectoryChanged;

  @override
  State<LocalBackupSettingsCard> createState() =>
      _LocalBackupSettingsCardState();
}

class _LocalBackupSettingsCardState extends State<LocalBackupSettingsCard> {
  /// 动作按钮的左右内缩，对齐卡内 `Divider(indent: 16)`。
  static const double _buttonInset = 16;

  final LocalBackupService _service = inject<LocalBackupService>();

  /// 展开态。总开关开着时进页面折叠（与【启用 WebDAV】卡一致）；
  /// 关着时进页面直接展开，好让两颗手动按钮露出来。
  late bool _expanded;

  /// 拨开关要联动展开/折叠，得拿到 `ExpansionTile` 的控制器。
  final ExpansibleController _tileController = ExpansibleController();

  /// 正在跑的动作：`'backup'` / `'restore'` / `'other'` / null。
  ///
  /// `'other'` 是拨总开关这类没有独立按钮的页级动作，此时所有按钮进忙碌态。
  String? _busyAction;

  bool get _busy => _busyAction != null;

  @override
  void initState() {
    super.initState();
    _expanded = !_service.enabled;
  }

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

  /// 手动备份。
  ///
  /// 与自动备份不同，这里不看总开关：总开关只管「改动后自动备份」，
  /// 手动点按钮任何时候都算数。
  ///
  /// 顺序是**先补目录、再查内容**：没目录时总开关是禁用的、四个内容开关也
  /// 是隐藏的，反过来的话用户会卡在「想备份却没有任何可点的开关」上。
  /// 选中的目录同时写进「本地备份路径」，总开关随即解除置灰。
  Future<void> _backup() async {
    if (_busy) return;
    if (_service.directory.isEmpty) {
      final selected = await _pickAndSaveDirectory();
      if (selected == null) return;
    }
    if (!_service.hasSelection) {
      KazumiDialog.showToast(message: '请开启本地备份并选择要备份的内容');
      return;
    }
    await _run(
      busyKey: 'backup',
      startMessage: '正在备份到本地…',
      successPrefix: '已备份',
      action: _service.backup,
    );
  }

  /// 手动恢复。
  ///
  /// 总开关关着时四个内容开关是隐藏的，用户没法挑内容，这时按全量恢复；
  /// 开着但一项都没选时同样退回全量 —— 恢复是按文件合并、缺的跳过，
  /// 让按钮直接可用比报「请先选择要恢复的内容」更符合预期。
  /// 还没设备份目录时一次性选目录，不写入设置。
  Future<void> _restore() async {
    if (_busy) return;
    final ignoreSelection = !_service.enabled || !_service.hasSelection;
    var source = _service.directory;
    if (source.isEmpty) {
      final selected = await _service.pickDirectoryOnce();
      if (!mounted || selected == null || selected.isEmpty) return;
      source = selected;
    }
    await _run(
      busyKey: 'restore',
      startMessage: '正在从本地恢复…',
      successPrefix: '已恢复',
      action: () async {
        final result = await _service.restore(
          sourceDirectory: source,
          ignoreSelection: ignoreSelection,
        );
        return result.detail;
      },
    );
  }

  /// 无目录时点备份：开目录选择器，选中就存成正式备份路径。
  Future<String?> _pickAndSaveDirectory() async {
    try {
      final selected = await _service.selectDirectory();
      if (!mounted || selected == null) return null;
      widget.onDirectoryChanged?.call();
      setState(() {});
      return selected;
    } catch (e) {
      KazumiLogger().w('LocalBackup: pick directory failed', error: e);
      if (mounted) KazumiDialog.showToast(message: '$e');
      return null;
    }
  }

  Future<void> _toggle(SettingKey<bool> key, bool value) async {
    await GStorage.putSetting(key, value);
    if (mounted) setState(() {});
  }

  /// 拨总开关时同步展开态：**总是展开**。
  ///
  /// 开启时展开是为了让人看到五个内容开关；关闭时五个开关会整块隐藏，
  /// 卡片只剩头部和两颗手动按钮，更要保持展开 —— 否则按钮被折叠起来，
  /// 用户还得再点一次才能手动备份。
  ///
  /// 与【启用 WebDAV】卡同款：`_expanded` 由 `onExpansionChanged` 统一更新，
  /// 这里只驱动控制器，免得两处赋值打架。
  Future<void> _toggleEnabled(bool value) async {
    if (_busy) return;
    _tileController.expand();
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
    // 没选目录时头部置灰；两颗手动按钮此时仍可点 —— 点下去会先让选目录。
    final dimmed = colors.onSurface.withValues(alpha: 0.38);
    final foreground = configured ? colors.onSurface : dimmed;
    final subtitleColor = configured ? secondary : dimmed;
    final subtitle = configured
        ? (enabled
              ? (followWebDav ? '已开启，备份选项跟随 WebDAV' : '已开启，请选择要备份内容')
              : '未开启，可用下方按钮手动备份或恢复')
        : '请先选择备份目录';
    // 手动按钮不看总开关，也不看有没有目录，只在动作进行中禁用。
    final canAct = !_busy;

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
          // 与【启用 WebDAV】卡同节奏：头部开关下先来一条线。
          const Divider(height: 1, indent: 16, endIndent: 16),
          // 五个内容开关只在总开关开启时出现：总开关关着时它们全是禁用态，
          // 摆在界面上既点不动又占地方，不如整块藏掉，只留下面两颗手动按钮。
          if (enabled) ...[
            // 放在分割线上方：它是选择器，不是四项内容之一。
            SettingsTile.switchTile(
              leading: Icons.cloud_sync_rounded,
              title: const Text('跟随同步'),
              description: const Text('让备份选项跟随 WebDAV'),
              initialValue: followWebDav,
              enabled: !_busy,
              onToggle: (value) =>
                  _toggle(SettingsKeys.localBackupFollowWebDav, value ?? false),
            ),
            // 跟随云端时四项由【启用 WebDAV】那边决定，这里全部藏起来：
            // 分割线也一起去掉，否则会剩一条悬空的线。
            if (!followWebDav) ...[
              const Divider(height: 1, indent: 16, endIndent: 16),
              SettingsTile.switchTile(
                leading: Icons.history_rounded,
                title: const Text('观看记录'),
                description: const Text('备份播放进度与历史记录'),
                initialValue: history,
                enabled: !_busy,
                onToggle: (value) => _toggle(
                  SettingsKeys.localBackupEnableHistory,
                  value ?? false,
                ),
              ),
              SettingsTile.switchTile(
                leading: Icons.favorite_rounded,
                title: const Text('收藏列表'),
                description: const Text('备份所有追番分类与收藏状态'),
                initialValue: collect,
                enabled: !_busy,
                onToggle: (value) => _toggle(
                  SettingsKeys.localBackupEnableCollect,
                  value ?? false,
                ),
              ),
              SettingsTile.switchTile(
                leading: Icons.filter_alt_rounded,
                title: const Text('弹幕屏蔽词'),
                description: const Text('备份关键词与正则表达式规则'),
                initialValue: shield,
                enabled: !_busy,
                onToggle: (value) => _toggle(
                  SettingsKeys.localBackupEnableDanmakuShield,
                  value ?? false,
                ),
              ),
              SettingsTile.switchTile(
                leading: Icons.key_rounded,
                title: const Text('用户凭据'),
                description: const Text('备份 Bangumi 与服务器账号信息（AES 加密存储）'),
                initialValue: credentials,
                enabled: !_busy,
                onToggle: (value) => _toggle(
                  SettingsKeys.localBackupEnableCredentials,
                  value ?? false,
                ),
              ),
            ],
          ],
          // 按钮区常驻：手动备份/恢复不看总开关，没设目录时点下去会先让选目录。
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
