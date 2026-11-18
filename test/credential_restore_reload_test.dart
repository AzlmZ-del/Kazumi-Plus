import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/backup/local_backup_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/bangumi_sync_service.dart';
import 'package:kazumi/services/sync/bangumi_web_session.dart';
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
    dir = await root.createTemp('kazumi_cred_restore_');
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

  group('credential restore resets cached login state', () {
    test('BangumiSyncService drops its verified state and notifies', () {
      final service = BangumiSyncService();
      var notified = 0;
      void listener() => notified++;
      service.addListener(listener);
      addTearDown(() => service.removeListener(listener));

      service.reloadAfterRestore();

      // 必须通知一次，页面（ListenableBuilder）才有机会重绘。
      expect(notified, 1);
      expect(service.username, isEmpty);
      expect(service.lastError, isNull);
    });

    test('reloadAfterRestore does not overwrite stored credentials', () async {
      // 恢复流程刚写好的 token 不能被重置逻辑抹掉。
      await GStorage.putSetting(
        SettingsKeys.bangumiAccessToken,
        'restored-token',
      );

      BangumiSyncService().reloadAfterRestore();

      expect(
        GStorage.getSetting(SettingsKeys.bangumiAccessToken),
        'restored-token',
      );
    });

    test('web session reload clears process-local login state only', () {
      final session = BangumiWebSession();
      // 没有备份 cookie 时必须判定为未登录，而不是沿用旧的 uid。
      session.reloadAfterRestore();

      expect(session.uid, 0);
    });
  });

  test('LocalBackupRestoreResult is unaffected by the credentials change', () {
    const result = LocalBackupRestoreResult(done: ['账号信息'], missing: []);
    expect(result.detail, '账号信息');
  });
}
