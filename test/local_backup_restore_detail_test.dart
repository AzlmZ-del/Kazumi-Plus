import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/backup/local_backup_service.dart';

void main() {
  group('LocalBackupRestoreResult.detail', () {
    test('settings restore no longer asks for a restart', () {
      const result = LocalBackupRestoreResult(
        done: ['应用设置'],
        missing: [],
        requiresRestart: true,
      );

      // 设置现在由 settingsReloaded 当场重读，不该再让用户去重启。
      expect(result.detail, contains('立即生效'));
      expect(result.detail, isNot(contains('重启')));
    });

    test('keeps the missing list when some files are absent', () {
      const result = LocalBackupRestoreResult(
        done: ['应用设置'],
        missing: ['收藏列表'],
        requiresRestart: true,
      );

      expect(result.detail, contains('未找到：收藏列表'));
      expect(result.detail, contains('立即生效'));
    });

    test('non-settings restore stays a plain list', () {
      const result = LocalBackupRestoreResult(done: ['观看记录'], missing: []);

      expect(result.detail, '观看记录');
      expect(result.detail, isNot(contains('生效')));
    });
  });
}
