import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/rules_mirror.dart';
import 'package:kazumi/services/network/rules_mirror_probe.dart';

void main() {
  group('latency tiering for the mirror picker', () {
    // 规则仓库加速的延迟配色直接吃 speedTierOf(ms)，这里锁定
    // 「探测结果给出的毫秒数」本身，确保边界不会被改写。
    test('fast mirror reports its real millisecond value', () {
      const result = RulesMirrorProbeResult(
        mode: RulesMirror.ghProxyCom,
        latency: Duration(milliseconds: 396),
        reachable: true,
      );
      expect(result.label, '396 ms');
      expect(result.latency.inMilliseconds, 396);
    });

    test('slow mirror keeps the measured value instead of being clipped', () {
      const result = RulesMirrorProbeResult(
        mode: RulesMirror.ghProxyNet,
        latency: Duration(milliseconds: 9533),
        reachable: true,
      );
      expect(result.label, '9533 ms');
    });

    test('unreachable reports elapsed time, not a vague word', () {
      const result = RulesMirrorProbeResult(
        mode: RulesMirror.ghfast,
        latency: Duration(milliseconds: 1500),
        reachable: false,
      );
      expect(result.label, contains('1500'));
      expect(result.label, isNot('不可用'));
    });
  });
}
