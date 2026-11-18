import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/settings/sync/local_backup_cards.dart';

void main() {
  group('LocalBackupSettingsCard contract', () {
    test('exposes an onRestored hook for the host page', () {
      // 恢复完成后，同页的服务器地址与账号都来自存储；本卡只重建自己不够，
      // 必须有一个钩子把「恢复完了」这件事交给页面。这里锁住该构造参数存在。
      final card = LocalBackupSettingsCard(
        onRestored: () {},
        onDirectoryChanged: () {},
      );

      expect(card.onRestored, isNotNull);
      expect(card.onDirectoryChanged, isNotNull);
    });

    test('both callbacks are optional so existing call sites keep working', () {
      const card = LocalBackupSettingsCard();

      expect(card.onRestored, isNull);
      expect(card.onDirectoryChanged, isNull);
    });
  });
}
