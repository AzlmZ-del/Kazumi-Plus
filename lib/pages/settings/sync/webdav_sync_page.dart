import 'package:flutter/material.dart';

import 'package:kazumi/bean/dialog/dialog.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/bean/widget/tonal_card.dart';
import 'package:kazumi/pages/settings/sync/local_backup_cards.dart';
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
  /// Horizontal inset of the action buttons, matching the card's `Divider(indent: 16)`
  /// and the same-named constant on the anime sync cards.
  static const double _buttonInset = 16;

  /// Key of the running action, set by `_runAction` for its duration: only that
  /// button shows a busy state, the others stay unchanged.
  ///
  /// `null` = idle. `'other'` = page-level actions without their own button,
  /// such as toggling the WebDAV switch; all action buttons go busy then.
  String? _busyAction;

  /// Busy while any action runs (shared by the mutex and `PopScope` interception).
  bool get _busy => _busyAction != null;

  bool _failed = false;
  String? _message;

  /// Whether the WebDAV card is expanded, revealing its content and sync buttons.
  bool _expanded = false;

  /// Controller for the `ExpansionTile`, so the switch can expand/collapse it.
  final ExpansibleController _enableController = ExpansibleController();

  // Always collapsed on entry: expanding needs a tap, the switch does not drive
  // it (in-page toggles still do, see `_toggleEnabled`).

  @override
  void dispose() {
    // The page owns the controller; `ExpansionTile` does not dispose it.
    _enableController.dispose();
    super.dispose();
  }

  /// Entry point for page-level actions: sets `_busyAction` to [busyKey] while
  /// [action] runs.
  ///
  /// [busyKey] picks the button showing the busy state (`'other'` = no own
  /// button, all busy). Further clicks are dropped here (mutex), but only the
  /// button matching busyKey changes.
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
        _message = showBusyFeedback ? '未能完成，请检查网络或服务器配置后重试。' : _message;
      }
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  /// Sync/backup actions report via toasts: start, success and failure all pop
  /// one, with no persistent feedback bar on the page.
  ///
  /// Only the triggering button ([busyKey]) shows busy; the mutex still comes
  /// from `_busy` and clicks during it are ignored here.
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

  Future<void> _setEnabled(bool enabled) => _runAction(
    busyKey: 'other',
    action: () async {
      await WebDav().setEnabled(enabled);
      _message = null;
    },
  );

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

  /// Rebuild the cards below when the backup directory changes; button states read it.
  void _onLocalBackupDirectoryChanged() {
    if (mounted) setState(() {});
  }

  /// Refresh the page after the server config is saved (or a failure disabled
  /// sync): `configured`, the host and the WebDAV card's dimmed state change.
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

  /// Whether any credential is stored locally (Bangumi token/account/cookie, WebDAV config).
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
            LocalBackupDirectoryCard(
              onDirectoryChanged: _onLocalBackupDirectoryChanged,
            ),
            LocalBackupSettingsCard(
              onDirectoryChanged: _onLocalBackupDirectoryChanged,
              // Reload the whole page after a restore: the server card's
              // address/account and the switch labels all come from storage.
              onRestored: () {
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  /// The WebDAV card: the switch is the header, expanding reveals content and buttons.
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
    final subtitle = configured ? null : '请先配置服务器';

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
        // 12dp on all sides of the expanded area, as in the other five cards.
        // The inner `SwitchListTile` adds 16dp of content padding, 28dp total.
        childrenPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        leading: Icon(Icons.cloud_sync_rounded, color: secondary),
        title: SyncCardTitle('启用 WebDAV', color: foreground),
        subtitle: subtitle == null
            ? null
            : SyncCardSubtitle(subtitle, color: secondary),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Collapsing is allowed during sync: it only hides the content and
            // the sync keeps running. The switch itself is still gated by `_busy`.
            Switch(
              value: enabled,
              onChanged: configured && !_busy ? _toggleEnabled : null,
              // The default 4dp horizontal padding inflates the control to 60dp;
              // removing it leaves exactly the track width.
              padding: EdgeInsets.zero,
            ),
            SyncExpandChevron(expanded: _expanded, color: secondary),
          ],
        ),
        onExpansionChanged: (value) => setState(() => _expanded = value),
        children: [
          const Divider(height: 1, indent: 16, endIndent: 16),
          SettingsTile.switchTile(
            leading: Icons.history_rounded,
            title: const Text('观看记录'),
            description: const Text('自动同步播放进度与历史记录'),
            initialValue: history,
            enabled: enabled && !_busy,
            onToggle: (value) async {
              await GStorage.putSetting(
                SettingsKeys.webDavEnableHistory,
                value ?? false,
              );
              if (mounted) setState(() {});
            },
          ),
          SettingsTile.switchTile(
            leading: Icons.favorite_rounded,
            title: const Text('收藏列表'),
            description: const Text('同步所有追番分类与收藏状态'),
            initialValue: collect,
            enabled: enabled && !_busy,
            onToggle: (value) async {
              await GStorage.putSetting(
                SettingsKeys.webDavEnableCollect,
                value ?? false,
              );
              if (mounted) setState(() {});
            },
          ),
          SettingsTile.switchTile(
            leading: Icons.filter_alt_rounded,
            title: const Text('弹幕屏蔽词'),
            description: const Text('启动和修改规则后自动同步，包含关键词与正则表达式'),
            initialValue: shield,
            enabled: enabled && !_busy,
            onToggle: (value) async {
              await GStorage.putSetting(
                SettingsKeys.webDavEnableDanmakuShield,
                value ?? false,
              );
              if (mounted) setState(() {});
            },
          ),
          SettingsTile.switchTile(
            leading: Icons.key_rounded,
            title: const Text('用户凭据'),
            description: const Text('开启后可备份/恢复 Bangumi 与服务器账号信息（AES 加密存储）'),
            initialValue: credentials,
            enabled: enabled && !_busy,
            onToggle: (value) async {
              await GStorage.putSetting(
                SettingsKeys.webDavEnableCredentials,
                value ?? false,
              );
              if (mounted) setState(() {});
            },
          ),
          // Hide the action buttons when the master switch is off: everything is
          // disabled anyway.
          if (enabled)
            Padding(
              // Another 16dp on top of childrenPadding's 12dp, aligning with the
              // inner `Divider(indent: 16)`; 10dp on top separates the switches.
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
              // Credential backup area: same 16dp inset as the buttons above, 10dp on top.
              padding: const EdgeInsets.symmetric(horizontal: _buttonInset),
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 10,
                  children: [
                    SyncActionButton(
                      onPressed:
                          configured && _busyAction == null && _hasAnyCredential
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

  /// Keep the expanded state in sync with the switch: on expands, off collapses.
  ///
  /// Only applies to in-page toggles; the initial state is always collapsed (see
  /// `_expanded`). `_expanded` is not set here — the controller-triggered
  /// `onExpansionChanged` updates it, so there is a single owner.
  Future<void> _toggleEnabled(bool value) async {
    if (value) {
      _enableController.expand();
    } else {
      _enableController.collapse();
    }
    await _setEnabled(value);
  }
}
