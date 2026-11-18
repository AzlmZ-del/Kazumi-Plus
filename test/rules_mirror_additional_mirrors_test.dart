import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/network/rules_mirror.dart';

void main() {
  const official = '${ApiEndpoints.pluginShop}index.json';
  const personal = '${ApiEndpoints.personalPluginShop}index.json';
  const third = 'https://example.com/my/index.json';

  group('prefix mirrors', () {
    test('prepend their own host to both built-in repositories', () {
      const expected = {
        RulesMirror.ghProxyCom: 'https://gh-proxy.com/',
        RulesMirror.ghProxyImciel: 'https://ghproxy.imciel.com/',
        RulesMirror.ghProxyNet: 'https://ghproxy.net/',
        RulesMirror.ghProxyCn: 'https://ghproxy.cn/',
      };
      for (final entry in expected.entries) {
        expect(entry.key.map(official), '${entry.value}$official');
        expect(entry.key.map(personal), '${entry.value}$personal');
      }
    });
  });

  group('jsDelivr', () {
    test('rewrites raw github urls into gh/<owner>/<repo>@<ref>/<path>', () {
      expect(
        RulesMirror.jsDelivr.map(official),
        'https://cdn.jsdelivr.net/gh/Predidit/KazumiRules@main/index.json',
      );
      expect(
        RulesMirror.jsDelivr.map(personal),
        'https://cdn.jsdelivr.net/gh/AzlmZ-del/Kazumi-Plus-Rules@main/index.json',
      );
      expect(
        RulesMirror.jsDelivrGcore.map(official),
        'https://gcore.jsdelivr.net/gh/Predidit/KazumiRules@main/index.json',
      );
    });

    test('applies to built-in repositories only', () {
      expect(RulesMirror.jsDelivr.appliesTo(official), isTrue);
      expect(RulesMirror.jsDelivr.appliesTo(personal), isTrue);
      expect(RulesMirror.jsDelivr.map(third), isNull);
      expect(RulesMirror.jsDelivr.appliesTo(third), isFalse);
    });
  });

  group('appliesTo', () {
    test('detects the mirrors that fall back instead of applying', () {
      // GitCode 与 ghproxy.cn 对个人仓库不生效。
      expect(RulesMirror.gitcode.appliesTo(official), isTrue);
      expect(RulesMirror.gitcode.appliesTo(personal), isFalse);
      // 实测 ghproxy.cn 两个内置仓库都返回 200，因此对个人仓库同样生效。
      expect(RulesMirror.ghProxyCn.appliesTo(official), isTrue);
      expect(RulesMirror.ghProxyCn.appliesTo(personal), isTrue);
    });

    test('direct never rewrites anything', () {
      expect(RulesMirror.direct.appliesTo(official), isFalse);
      expect(RulesMirror.direct.map(official), isNull);
    });

    test('third-party repositories are never rewritten by any mirror', () {
      for (final mode in RulesMirror.values) {
        expect(mode.map(third), isNull, reason: mode.name);
        expect(mode.appliesTo(third), isFalse, reason: mode.name);
      }
    });
  });

  test('every mirror has a distinct label', () {
    final labels = {for (final mode in RulesMirror.values) mode.label};
    expect(labels, hasLength(RulesMirror.values.length));
  });
}
