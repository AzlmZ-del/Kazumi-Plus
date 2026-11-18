import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/network/rules_mirror.dart';

void main() {
  const personal = '${ApiEndpoints.personalPluginShop}index.json';
  const official = '${ApiEndpoints.pluginShop}index.json';

  test('gitcode marks itself as official-only', () {
    expect(RulesMirror.gitcode.mirrorsOnlyOfficial, isTrue);
    for (final mode in RulesMirror.values) {
      if (mode == RulesMirror.gitcode) continue;
      expect(mode.mirrorsOnlyOfficial, isFalse, reason: mode.name);
    }
  });

  test('gitcode falls back to gh-proxy for the personal repository', () {
    // 探测据此判定「对当前仓库不生效」：映射结果不是 GitCode 前缀，
    // 说明用户即使选了 GitCode，读个人仓库时实际走的是 gh-proxy。
    final mapped = RulesMirror.gitcode.map(personal);
    expect(mapped, isNotNull);
    expect(mapped, startsWith(ApiEndpoints.ghProxyMirror));
    expect(mapped, isNot(startsWith(ApiEndpoints.gitcodeMirror)));
  });

  test('gitcode really maps the official repository onto itself', () {
    final mapped = RulesMirror.gitcode.map(official);
    expect(mapped, startsWith(ApiEndpoints.gitcodeMirror));
  });
}
