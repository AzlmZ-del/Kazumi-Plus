import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/rules_mirror.dart';
import 'package:kazumi/services/network/rules_mirror_probe.dart';

void main() {
  test('direct comes first and is labelled GitHub', () {
    expect(RulesMirror.values.first, RulesMirror.direct);
    expect(RulesMirror.direct.label, 'GitHub');
  });

  test('gitcode comes second', () {
    expect(RulesMirror.values[1], RulesMirror.gitcode);
  });

  test('all prefix mirrors share the same base description', () {
    for (final mode in [
      RulesMirror.ghProxy,
      RulesMirror.ghfast,
      RulesMirror.ghProxyCom,
      RulesMirror.ghProxyImciel,
      RulesMirror.ghProxyNet,
      RulesMirror.ghProxyCn,
    ]) {
      expect(mode.description, '备用镜像', reason: mode.name);
    }
  });

  test('slow mirrors get a longer probe timeout, not a vague label', () {
    // 慢镜像用统一短超时会被判成「不可用」，掩盖真实延迟。
    expect(RulesMirror.ghProxyCn.probeTimeout.inSeconds, 15);
    expect(RulesMirror.ghProxyNet.probeTimeout.inSeconds, 8);
    for (final mode in [
      RulesMirror.ghProxy,
      RulesMirror.ghProxyCom,
      RulesMirror.jsDelivr,
      RulesMirror.direct,
    ]) {
      expect(mode.probeTimeout, RulesMirrorProbe.timeout, reason: mode.name);
    }
  });

  test('enum order stays stable for the picker', () {
    expect(RulesMirror.values, [
      RulesMirror.direct,
      RulesMirror.gitcode,
      RulesMirror.ghProxy,
      RulesMirror.ghfast,
      RulesMirror.ghProxyCom,
      RulesMirror.ghProxyImciel,
      RulesMirror.ghProxyNet,
      RulesMirror.ghProxyCn,
      RulesMirror.jsDelivr,
      RulesMirror.jsDelivrGcore,
    ]);
  });
}
