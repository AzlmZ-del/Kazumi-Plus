import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/backup/local_backup_items.dart';
import 'package:kazumi/services/storage/settings_keys.dart';

/// 声明表一旦与设置注册表脱节，「界面藏了、服务层照做」的错位就会复现。
void main() {
  final registeredNames = {for (final key in SettingsKeys.all) key.name};

  test('every item declares a registered local switch', () {
    for (final item in localBackupItems) {
      expect(
        registeredNames,
        contains(item.localKey.name),
        reason: '${item.title} 的本地开关 ${item.localKey.name} 未注册到 SettingsKeys.all',
      );
    }
  });

  test('web dav switches are registered too', () {
    for (final item in localBackupItems) {
      final key = item.webDavKey;
      if (key == null) continue;
      expect(
        registeredNames,
        contains(key.name),
        reason: '${item.title} 的云端开关 ${key.name} 未注册到 SettingsKeys.all',
      );
    }
  });

  test('every section appears exactly once', () {
    final sections = localBackupItems.map((item) => item.section).toList();
    expect(sections.toSet().length, sections.length);
    expect(sections.toSet(), LocalBackupSection.values.toSet());
  });

  test('file names are unique across items', () {
    final names = [
      for (final item in localBackupItems) ...item.fileNames,
    ];
    expect(names.toSet().length, names.length, reason: '两项写了同一个文件名');
    for (final name in names) {
      expect(
        name.endsWith('.hive') || name.endsWith('.json'),
        isTrue,
        reason: '$name 不是 Hive 箱或 JSON 文件',
      );
    }
  });

  test('titles are unique and non-empty', () {
    final titles = localBackupItems.map((item) => item.title).toList();
    expect(titles.toSet().length, titles.length);
    expect(titles, everyElement(isNotEmpty));
  });

  test('settings item stays local-only and out of auto backup', () {
    final settings = localBackupItems.firstWhere(
      (item) => item.section == LocalBackupSection.settings,
    );
    // 云端没有整箱设置这一项，跟随开关不该管它 —— 界面据此让它常驻显示。
    expect(settings.followsWebDav, isFalse);
    expect(settings.webDavKey, isNull);
    // 整箱导出代价大，不参与「改动即备份」。
    expect(settings.autoBackup, isFalse);
    expect(settings.restoreNeedsRestart, isTrue);
  });

  test('other items follow web dav and participate in auto backup', () {
    for (final item in localBackupItems) {
      if (item.section == LocalBackupSection.settings) continue;
      expect(item.followsWebDav, isTrue, reason: '${item.title} 应该跟随 WebDAV');
      expect(item.autoBackup, isTrue, reason: '${item.title} 应参与自动备份');
      expect(item.restoreNeedsRestart, isFalse);
    }
  });
}
