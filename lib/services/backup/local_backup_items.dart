import 'package:flutter/material.dart';

import 'package:kazumi/services/storage/settings_keys.dart';

/// 本地备份的内容分区。
///
/// 「收藏列表」固定占 `collectibles` + `collectchanges` 两个文件，缺一个恢复就会丢变更。
enum LocalBackupSection { history, collect, shield, credentials, settings }

/// 一项可备份内容的声明。服务层写盘/恢复、界面生成开关行都遍历这张表，
/// 避免两处各维护一份清单而走偏。
class LocalBackupItem {
  const LocalBackupItem({
    required this.section,
    required this.title,
    required this.description,
    required this.icon,
    required this.localKey,
    required this.fileNames,
    this.webDavKey,
    this.autoBackup = true,
    this.restoreNeedsRestart = false,
  });

  final LocalBackupSection section;

  /// 界面标题，同时用作备份/恢复结果里的条目名。
  final String title;

  final String description;

  final IconData icon;

  final SettingKey<bool> localKey;

  final List<String> fileNames;

  /// 跟随 WebDAV 时改读的开关；null 表示云端没有对应内容，永远只看 [localKey]。
  final SettingKey<bool>? webDavKey;

  /// 整箱设置导出代价大，不跟着高频事件重写。
  final bool autoBackup;

  /// 主题、字号等要重启才生效，恢复后需提示。
  final bool restoreNeedsRestart;

  bool get followsWebDav => webDavKey != null;
}

/// 本地备份的全部内容项，顺序即界面顺序。
const List<LocalBackupItem> localBackupItems = [
  LocalBackupItem(
    section: LocalBackupSection.history,
    title: '观看记录',
    description: '备份播放进度与历史记录',
    icon: Icons.history_rounded,
    localKey: SettingsKeys.localBackupEnableHistory,
    fileNames: ['kazumi-history.hive'],
    webDavKey: SettingsKeys.webDavEnableHistory,
  ),
  LocalBackupItem(
    section: LocalBackupSection.collect,
    title: '收藏列表',
    description: '备份所有追番分类与收藏状态',
    icon: Icons.favorite_rounded,
    localKey: SettingsKeys.localBackupEnableCollect,
    fileNames: ['kazumi-collectibles.hive', 'kazumi-collectchanges.hive'],
    webDavKey: SettingsKeys.webDavEnableCollect,
  ),
  LocalBackupItem(
    section: LocalBackupSection.shield,
    title: '弹幕屏蔽词',
    description: '备份关键词与正则表达式规则',
    icon: Icons.filter_alt_rounded,
    localKey: SettingsKeys.localBackupEnableDanmakuShield,
    fileNames: ['kazumi-danmaku-shield.json'],
    webDavKey: SettingsKeys.webDavEnableDanmakuShield,
  ),
  LocalBackupItem(
    section: LocalBackupSection.credentials,
    title: '用户凭据',
    description: '备份 Bangumi 与服务器账号信息（AES 加密存储）',
    icon: Icons.key_rounded,
    localKey: SettingsKeys.localBackupEnableCredentials,
    fileNames: ['kazumi-credentials.json'],
    webDavKey: SettingsKeys.webDavEnableCredentials,
  ),
  LocalBackupItem(
    section: LocalBackupSection.settings,
    title: '应用设置',
    description: '备份开关、参数与输入框内容（不含账号口令）',
    icon: Icons.tune_rounded,
    localKey: SettingsKeys.localBackupEnableSettings,
    fileNames: ['kazumi-settings.hive'],
    autoBackup: false,
    restoreNeedsRestart: true,
  ),
];
