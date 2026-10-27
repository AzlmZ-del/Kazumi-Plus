import 'package:flutter/material.dart';

import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/widget/tonal_card.dart';
import 'package:kazumi/pages/settings/sync/sync_settings_widgets.dart';
import 'package:kazumi/pages/settings/sync/webdav_server_card.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:kazumi/services/sync/danmaku_shield_sync_service.dart';

class WebDavSyncPage extends StatefulWidget {
  const WebDavSyncPage({super.key, required this.danmakuShieldSync});

  final DanmakuShieldSyncService danmakuShieldSync;

  @override
  State<WebDavSyncPage> createState() => _WebDavSyncPageState();
}

class _WebDavSyncPageState extends State<WebDavSyncPage> {
  /// 动作按钮的左右内缩，对齐卡内 `Divider(indent: 16)`，
  /// 与「追番同步」页各卡的同名常量取同一个值。
  static const double _buttonInset = 16;

  /// 正在执行的动作标识。每个动作一个 key，`_runAction` 期间置为该 key：
  /// 只有对应按钮显示忙碌态，其余按钮保持原样（互斥由 `_busy` 判定拦截）。
  ///
  /// `null` = 空闲。`'other'` = 「启用 WebDAV」开关拨动这类没有独立按钮的
  /// 页级动作，此时所有动作按钮都进忙碌态。
  String? _busyAction;

  /// 任意动作在跑即视为忙碌（互斥 + `PopScope` 返回拦截共用）。
  bool get _busy => _busyAction != null;

  bool _failed = false;
  String? _message;

  /// 「启用 WebDAV」卡片是否展开。展开后下方露出要同步的内容与手动同步按钮。
  bool _expanded = false;

  /// 拨开关时要联动展开/折叠，得拿到 `ExpansionTile` 的控制器。
  final ExpansibleController _enableController = ExpansibleController();

  // 进页面一律折叠：展开态不跟开关联动，要自己点开。
  // （页内拨开关时仍会跟着展开/折叠，见 `_toggleEnabled`。）

  @override
  void dispose() {
    // 控制器由本页持有，`ExpansionTile` 不会替我们释放。
    _enableController.dispose();
    super.dispose();
  }

  /// 页级动作统一入口：跑 [action] 前把 `_busyAction` 置为 [busyKey]。
  ///
  /// [busyKey] 决定哪颗按钮显示忙碌态（`'other'` = 无独立按钮的页级动作，
  /// 全部按钮进忙碌态）。忙碌期间再点任何动作都会在这里被拦掉（互斥），
  /// 但 UI 上只有 busyKey 对应的按钮变化。
  Future<void> _runAction({
    required String busyKey,
    required Future<void> Function() action,
    bool showBusyFeedback = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busyAction = busyKey;
      _failed = false;
      _message = showBusyFeedback ? '正在连接 WebDAV…' : null;
    });
    try {
      await action();
    } catch (e) {
      KazumiLogger().w('WebDAV settings operation failed', error: e);
      if (mounted) {
        _failed = true;
        _message = showBusyFeedback
            ? '未能完成，请检查网络或服务器配置后重试。'
            : _message;
      }
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  /// 同步/备份动作统一走胶囊提示：开始、成功、失败都弹 toast，
  /// 不往页面里塞常驻反馈条（同步耗时长时那条会一直挂着，反而碍眼）。
  ///
  /// 忙碌态只标在触发按钮上（[busyKey]），其余按钮视觉不变；
  /// 互斥仍由 `_busy` 判定，忙碌期间的点击在这里直接忽略。
  Future<void> _runSync({
    required String busyKey,
    required String startMessage,
    required String successMessage,
    required Future<void> Function() action,
  }) {
    return _runAction(
      busyKey: busyKey,
      action: () async {
        KazumiDialog.showToast(message: startMessage);
        try {
          await action();
          KazumiDialog.showToast(message: successMessage);
        } catch (e) {
          KazumiLogger().w('WebDAV settings operation failed', error: e);
          KazumiDialog.showToast(message: '未能完成，请检查网络或服务器配置后重试。');
        }
      },
    );
  }

  Future<void> _setEnabled(bool enabled) =>
      _runAction(busyKey: 'other', action: () async {
        await WebDav().setEnabled(enabled);
        _message = null;
      });

  Future<void> _syncHistory() => _runSync(
    busyKey: 'history',
    startMessage: '正在同步观看记录…',
    successMessage: '观看记录已同步',
    action: () async {
      final webDav = WebDav();
      if (!webDav.initialized) {
        await webDav.init();
      } else if (!webDav.isHistorySyncing) {
        await webDav.ping();
      }
      await webDav.syncHistory();
    },
  );

  /// 服务器配置保存成功（或失败关掉了同步）后刷新本页：
  /// `configured` / 域名 / 「启用 WebDAV」卡的置灰状态都跟着变。
  void _onConfigurationChanged() {
    if (mounted) {
      setState(() {
        _message = null;
        _failed = false;
      });
    }
  }

  Future<void> _syncCollectibles() => _runSync(
    busyKey: 'collect',
    startMessage: '正在同步收藏列表…',
    successMessage: '收藏列表已同步',
    action: () async {
      final webDav = WebDav();
      if (!webDav.initialized) {
        await webDav.init();
      } else {
        await webDav.ping();
      }
      await webDav.syncCollectibles();
    },
  );

  Future<void> _syncDanmakuShield() => _runSync(
    busyKey: 'shield',
    startMessage: '正在同步弹幕屏蔽词…',
    successMessage: '弹幕屏蔽词已同步',
    action: () => widget.danmakuShieldSync.sync(),
  );

  /// 本地是否存有任何凭据（Bangumi Token/账密/Cookie、WebDAV 配置）。
  bool get _hasAnyCredential => WebDav().hasAnyCredential;

  Future<void> _uploadCredentials() => _runSync(
    busyKey: 'uploadCredentials',
    startMessage: '正在备份账号信息…',
    successMessage: '账号信息已备份到云端',
    action: () async {
      final webDav = WebDav();
      if (!_hasAnyCredential) {
        throw Exception('本地还没有可备份的账号信息');
      }
      if (!webDav.initialized) {
        await webDav.init();
      } else {
        await webDav.ping();
      }
      await webDav.uploadCredentials();
    },
  );

  Future<void> _restoreCredentials() => _runSync(
    busyKey: 'restoreCredentials',
    startMessage: '正在恢复账号信息…',
    successMessage: '账号信息已恢复',
    action: () async {
      final webDav = WebDav();
      if (!webDav.initialized) {
        await webDav.init();
      } else {
        await webDav.ping();
      }
      await webDav.restoreCredentials();
      if (mounted) setState(() {});
    },
  );

  @override
  Widget build(BuildContext context) {
    final enabled = GStorage.getSetting(SettingsKeys.webDavEnable);
    final history = GStorage.getSetting(SettingsKeys.webDavEnableHistory);
    final collect = GStorage.getSetting(SettingsKeys.webDavEnableCollect);
    final shield = GStorage.getSetting(SettingsKeys.webDavEnableDanmakuShield);
    final credentials = GStorage.getSetting(
      SettingsKeys.webDavEnableCredentials,
    );
    final url = GStorage.getSetting(SettingsKeys.webDavURL).trim();
    final configured = url.isNotEmpty;
    return PopScope(
      canPop: !_busy,
      child: SettingsDetailScaffold(
        title: const Text('多设备同步'),
        body: SyncPageBody(
          maxWidth: 720,
          spacing: 15,
          children: [
            const SyncPageIntro(
              icon: Icons.devices_rounded,
              title: 'WebDAV',
              description: '连接自己的云盘，同步观看记录、收藏列表与弹幕屏蔽词。',
            ),
            WebDavServerCard(onConfigurationChanged: _onConfigurationChanged),
            _enableCard(
              configured: configured,
              enabled: enabled,
              history: history,
              collect: collect,
              shield: shield,
              credentials: credentials,
            ),
            if (_message != null)
              SyncFeedback(message: _message!, error: _failed, busy: _busy),
          ],
        ),
      ),
    );
  }

  /// 「启用 WebDAV」卡片：头部是开关，展开后露出要同步的内容与手动同步按钮。
  Widget _enableCard({
    required bool configured,
    required bool enabled,
    required bool history,
    required bool collect,
    required bool shield,
    required bool credentials,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dimmed = colors.onSurface.withValues(alpha: 0.38);
    final foreground = configured ? colors.onSurface : dimmed;
    final secondary = configured ? colors.onSurfaceVariant : dimmed;
    final subtitle = configured
        ? (enabled ? '已开启，请选择要同步内容' : '开启后选择要同步的内容')
        : '请先配置服务器';

    return TonalCard(
      elevation: kSyncCardElevation,
      child: ExpansionTile(
        controller: _enableController,
        initiallyExpanded: _expanded,
        maintainState: true,
        shape: const Border(),
        collapsedShape: const Border(),
        minTileHeight: kSyncCardTileHeight,
        tilePadding: const EdgeInsets.symmetric(horizontal: 20),
        // 展开区四边统一 12dp（与其余五张卡一致）。
        // 里面的 `SwitchListTile` 自带 16dp 内容边距，合计 28dp。
        childrenPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        leading: Icon(Icons.cloud_sync_rounded, color: secondary),
        title: SyncCardTitle('启用 WebDAV', color: foreground),
        subtitle: SyncCardSubtitle(subtitle, color: secondary),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 同步中也允许收起：收起来只是把内容区藏了，同步照旧在后台跑，
            // 再点开还能看到进度。开关本身仍受 `_busy` 限制。
            Switch(
              value: enabled,
              onChanged: configured && !_busy ? _toggleEnabled : null,
            ),
            SyncExpandChevron(expanded: _expanded, color: secondary),
          ],
        ),
        onExpansionChanged: (value) => setState(() => _expanded = value),
        children: [
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile(
            secondary: Icon(Icons.history_rounded, size: 24, color: secondary),
            title: const Text('观看记录'),
            subtitle: Text(
              '自动同步播放进度与历史记录',
              style: syncSwitchSubtitleStyle(context),
            ),
            value: history,
            onChanged: enabled && !_busy
                ? (value) async {
                    await GStorage.putSetting(
                      SettingsKeys.webDavEnableHistory,
                      value,
                    );
                    if (mounted) setState(() {});
                  }
                : null,
          ),
          SwitchListTile(
            secondary: Icon(Icons.favorite_rounded, size: 24, color: secondary),
            title: const Text('收藏列表'),
            subtitle: Text(
              '同步所有追番分类与收藏状态',
              style: syncSwitchSubtitleStyle(context),
            ),
            value: collect,
            onChanged: enabled && !_busy
                ? (value) async {
                    await GStorage.putSetting(
                      SettingsKeys.webDavEnableCollect,
                      value,
                    );
                    if (mounted) setState(() {});
                  }
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
              '启动和修改规则后自动同步，包含关键词与正则表达式',
              style: syncSwitchSubtitleStyle(context),
            ),
            value: shield,
            onChanged: enabled && !_busy
                ? (value) async {
                    await GStorage.putSetting(
                      SettingsKeys.webDavEnableDanmakuShield,
                      value,
                    );
                    if (mounted) setState(() {});
                  }
                : null,
          ),
          SwitchListTile(
            secondary: Icon(Icons.key_rounded, size: 24, color: secondary),
            title: const Text('用户凭据'),
            subtitle: Text(
              '开启后可备份/恢复 Bangumi 与服务器账号信息（AES 加密存储）',
              style: syncSwitchSubtitleStyle(context),
            ),
            value: credentials,
            onChanged: enabled && !_busy
                ? (value) async {
                    await GStorage.putSetting(
                      SettingsKeys.webDavEnableCredentials,
                      value,
                    );
                    if (mounted) setState(() {});
                  }
                : null,
          ),
          // 总开关关闭时不显示动作按钮区：开关都禁用了，按钮留着也没法点。
          if (enabled)
            Padding(
              // 横向在 childrenPadding 的 12dp 之上再缩 16dp，对齐卡内
              // `Divider(indent: 16, endIndent: 16)`；顶部 10dp 与上面的开关列表拉开。
              padding: const EdgeInsets.symmetric(horizontal: _buttonInset),
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 10,
                  children: [
                    SyncActionButton(
                      onPressed: history && _busyAction == null
                          ? _syncHistory
                          : null,
                      text: _busyAction == 'history' || _busyAction == 'other'
                          ? '请稍候…'
                          : '立即同步观看记录',
                      icon: Icons.sync_rounded,
                    ),
                  SyncActionButton(
                    onPressed: collect && _busyAction == null
                        ? _syncCollectibles
                        : null,
                    text: _busyAction == 'collect' || _busyAction == 'other'
                        ? '请稍候…'
                        : '立即同步收藏列表',
                    icon: Icons.sync_rounded,
                  ),
                  SyncActionButton(
                    onPressed: shield && _busyAction == null
                        ? _syncDanmakuShield
                        : null,
                    text: _busyAction == 'shield' || _busyAction == 'other'
                        ? '请稍候…'
                        : '立即同步弹幕屏蔽词',
                    icon: Icons.sync_rounded,
                  ),
                ],
              ),
            ),
          ),
          if (enabled && credentials)
            Padding(
              // 「账号信息备份」区：与上方按钮区同款 16dp 内缩，顶部 10dp 拉开。
              padding: const EdgeInsets.symmetric(horizontal: _buttonInset),
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 10,
                  children: [
                    SyncActionButton(
                      onPressed: configured &&
                              _busyAction == null &&
                              _hasAnyCredential
                          ? _uploadCredentials
                          : null,
                      text:
                          _busyAction == 'uploadCredentials' ||
                              _busyAction == 'other'
                          ? '请稍候…'
                          : '备份账号信息到云端',
                      icon: Icons.cloud_upload_rounded,
                    ),
                    SyncActionButton(
                      onPressed: configured && _busyAction == null
                          ? _restoreCredentials
                          : null,
                      text:
                          _busyAction == 'restoreCredentials' ||
                              _busyAction == 'other'
                          ? '请稍候…'
                          : '从云端恢复账号信息',
                      icon: Icons.cloud_download_rounded,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 拨开关时同步展开态：开启就展开、关闭就折叠。
  ///
  /// 只在**页内拨动**时生效；进页面时的初始态固定为折叠（见 `_expanded` 定义）。
  /// `_expanded` 不在这里改 —— 控制器触发的 `onExpansionChanged` 会统一更新它，
  /// 免得两处赋值打架。
  Future<void> _toggleEnabled(bool value) async {
    if (value) {
      _enableController.expand();
    } else {
      _enableController.collapse();
    }
    await _setEnabled(value);
  }
}
