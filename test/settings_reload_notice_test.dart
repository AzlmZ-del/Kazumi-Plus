import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  late Directory dir;
  late PathProviderPlatform original;

  setUpAll(() async {
    final root = await Directory('tmp').create(recursive: true);
    dir = await root.createTemp('kazumi_settings_reload_');
    original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(dir.path);
    Hive.init(dir.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = original;
    await dir.delete(recursive: true);
  });

  test('restoring the settings box notifies subscribers', () async {
    // 造一份备份：写入一个可观察的开关再导出。
    await GStorage.putSetting(SettingsKeys.useDynamicColor, false);
    final file = '${dir.path}/kazumi-settings.hive';
    await GStorage.exportSettingsBox(file);

    // 先改成本地值，恢复后应当被备份值覆盖。
    await GStorage.putSetting(SettingsKeys.useDynamicColor, true);

    final seen = <void>[];
    final sub = GStorage.settingsReloaded.listen(seen.add);
    addTearDown(sub.cancel);

    await GStorage.restoreSettingsBox(file);
    // 广播流是异步投递的，需要让出事件队列才能收到。
    await pumpEventQueue();

    // 恢复后必须发一次通知，否则界面只能重启才生效。
    expect(seen, hasLength(1));
    expect(GStorage.getSetting(SettingsKeys.useDynamicColor), isFalse);
  });

  test(
    'notice carries no per-key filtering so bulk restore is covered',
    () async {
      final file = '${dir.path}/kazumi-settings2.hive';
      await GStorage.exportSettingsBox(file);

      var count = 0;
      final sub = GStorage.settingsReloaded.listen((_) => count++);
      addTearDown(sub.cancel);

      await GStorage.restoreSettingsBox(file);
      await GStorage.restoreSettingsBox(file);
      await pumpEventQueue();

      expect(count, 2);
    },
  );
}
