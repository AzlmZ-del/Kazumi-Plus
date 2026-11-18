import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/rules_mirror.dart';
import 'package:kazumi/services/network/rules_mirror_probe.dart';

void main() {
  group('RulesMirrorProbeResult json', () {
    test('round-trips a reachable result', () {
      const original = RulesMirrorProbeResult(
        mode: RulesMirror.ghProxy,
        latency: Duration(milliseconds: 321),
        reachable: true,
      );

      final restored = RulesMirrorProbeResult.fromJson(original.toJson());

      expect(restored, isNotNull);
      expect(restored!.mode, RulesMirror.ghProxy);
      expect(restored.latency, const Duration(milliseconds: 321));
      expect(restored.reachable, isTrue);
      expect(restored.notApplicable, isFalse);
    });

    test('round-trips the not-applicable flag', () {
      const original = RulesMirrorProbeResult(
        mode: RulesMirror.gitcode,
        latency: Duration(milliseconds: 12),
        reachable: true,
        notApplicable: true,
      );

      final restored = RulesMirrorProbeResult.fromJson(original.toJson());

      expect(restored!.notApplicable, isTrue);
      expect(restored.label, '对当前仓库不生效');
    });

    test('keeps unavailable results unavailable', () {
      const original = RulesMirrorProbeResult(
        mode: RulesMirror.ghfast,
        latency: Duration(milliseconds: 1500),
        reachable: false,
      );

      final restored = RulesMirrorProbeResult.fromJson(original.toJson());

      expect(restored!.reachable, isFalse);
      // 失败也报真实耗时，不再用「不可用」这种模糊说法。
      expect(restored.label, '1500 ms 无响应');
    });

    test('rejects malformed cache entries instead of throwing', () {
      for (final raw in <Object?>[
        null,
        'text',
        <String, dynamic>{},
        {'mode': 'nope', 'ms': 1, 'reachable': true},
        {'mode': 'ghProxy', 'ms': '1', 'reachable': true},
        {'mode': 'ghProxy', 'ms': 1, 'reachable': 'yes'},
      ]) {
        expect(RulesMirrorProbeResult.fromJson(raw), isNull);
      }
    });
  });
}
