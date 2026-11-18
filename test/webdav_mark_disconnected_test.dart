import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/sync/webdav.dart';

void main() {
  group('WebDav.markDisconnected', () {
    test('clears the connection flag the server card dot reads', () {
      final webDav = WebDav();
      // 直接置位模拟「恢复前已连上」，圆点此时是绿的。
      webDav.initialized = true;

      webDav.markDisconnected();

      // 恢复后必须回到未连接，卡片才会按新凭据重连；否则要重启才变。
      expect(webDav.initialized, isFalse);
      expect(webDav.isPinging, isFalse);
      expect(webDav.lastPingError, isNull);
    });

    test('is a no-op on an already disconnected instance', () {
      final webDav = WebDav();
      webDav.markDisconnected();
      webDav.markDisconnected();

      expect(webDav.initialized, isFalse);
    });
  });
}
