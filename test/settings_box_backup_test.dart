import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';

/// `GStorage._setting` 只在 App 启动后存在，这里用同名临时箱复刻导出/恢复的读写方式。
void main() {
  setUpAll(() => Logger.level = Level.off);

  const exportBoxName = 'kazumiSettingsExport';
  const restoreBoxName = 'kazumiSettingsRestore';
  const excluded = GStorage.settingBackupExcludedKeys;

  late Directory boxDir;
  late Box<dynamic> box;

  setUp(() async {
    boxDir = await Directory.systemTemp.createTemp('kazumi-settings-test-');
    box = await Hive.openBox('setting', path: boxDir.path);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('setting', path: boxDir.path);
    if (await boxDir.exists()) await boxDir.delete(recursive: true);
  });

  String boxPath(String dir, String name) => '$dir/${name.toLowerCase()}.hive';

  test('exported file round-trips through a fresh temp box', () async {
    await box.putAll({
      'themeMode': 2,
      'danmakuOpacity': 0.75,
      'searchEnhanceEnable': true,
      'defaultStartupPage': '/timeline',
      'webDavPasswd': 'should-not-leak',
    });

    final backup = '${boxDir.path}/kazumi-settings.hive';
    final exportDir = await Directory.systemTemp.createTemp('kazumi-exp-');
    try {
      final exportBox = await Hive.openBox(exportBoxName, path: exportDir.path);
      await exportBox.putAll({
        for (final entry in box.toMap().entries)
          if (!excluded.contains(entry.key)) entry.key: entry.value,
      });
      await exportBox.flush();
      await exportBox.close();
      await File(boxPath(exportDir.path, exportBoxName)).copy(backup);
    } finally {
      if (await exportDir.exists()) await exportDir.delete(recursive: true);
    }

    // 备份文件里不能出现口令。
    expect(await File(backup).exists(), isTrue);

    // 模拟「整箱覆盖」：清空后按备份写回。
    final readDir = await Directory.systemTemp.createTemp('kazumi-read-');
    final Map<dynamic, dynamic> entries;
    try {
      await File(backup).copy(boxPath(readDir.path, restoreBoxName));
      final readBox = await Hive.openBox(restoreBoxName, path: readDir.path);
      try {
        entries = readBox.toMap();
      } finally {
        await readBox.close();
      }
    } finally {
      if (await readDir.exists()) await readDir.delete(recursive: true);
    }

    await box.clear();
    await box.putAll(entries);

    expect(box.get('themeMode'), 2);
    expect(box.get('danmakuOpacity'), 0.75);
    expect(box.get('searchEnhanceEnable'), isTrue);
    expect(box.get('defaultStartupPage'), '/timeline');
    expect(box.get('webDavPasswd'), isNull);
  });

  test('excluded keys cover credentials but not ordinary settings', () {
    expect(excluded, contains('bangumiAccessToken'));
    expect(excluded, contains('bangumiWebPassword'));
    expect(excluded, contains('webDavPasswd'));
    expect(excluded, isNot(contains('themeMode')));
    expect(excluded, isNot(contains('danmakuOpacity')));
  });

  test('restoring an empty snapshot clears the box', () async {
    await box.putAll({'autoPlay': true, 'themeMode': 1});
    expect(box.length, 2);

    await box.clear();
    await box.putAll({});

    expect(box.isEmpty, isTrue);
  });

  test('settings restore keeps local credentials alive', () {
    // 回归：整箱覆盖曾把刚恢复的凭据一起清掉，导致「恢复后账号丢了」。
    final merged = GStorage.mergeSettingsForRestore(
      current: {
        'bangumiAccessToken': 'tok',
        'webDavPasswd': 'pw',
        'themeMode': 'dark',
        'staleKey': 1,
      },
      backup: {
        'themeMode': 'light',
        'danmakuOpacity': 0.5,
        // 备份里即使混入凭据也不该回灌。
        'bangumiAccessToken': 'old-tok-from-backup',
      },
    );

    expect(merged['bangumiAccessToken'], 'tok', reason: '应保留本机凭据而非备份里的旧值');
    expect(merged['webDavPasswd'], 'pw');
    expect(merged['themeMode'], 'light', reason: '非凭据键应被备份覆盖');
    expect(merged['danmakuOpacity'], 0.5);
    expect(merged.containsKey('staleKey'), isFalse, reason: '备份里没有的键应被清掉');
  });

  test('settings restore keeps every excluded key that exists locally', () {
    final merged = GStorage.mergeSettingsForRestore(
      current: {for (final key in GStorage.settingBackupExcludedKeys) key: 'v-$key'},
      backup: {'themeMode': 'light'},
    );
    for (final key in GStorage.settingBackupExcludedKeys) {
      expect(merged[key], 'v-$key');
    }
    expect(merged['themeMode'], 'light');
  });
}
