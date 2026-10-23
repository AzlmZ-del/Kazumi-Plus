import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/network/rules_mirror.dart';

void main() {
  const official = '${ApiEndpoints.pluginShop}index.json';
  const personal = '${ApiEndpoints.personalPluginShop}Hanime1.json';
  const third = 'https://example.com/my/index.json';

  test('ghProxy prefixes the whole url', () {
    expect(
      RulesMirror.ghProxy.map(official),
      'https://cdn.gh-proxy.org/$official',
    );
    expect(
      RulesMirror.ghProxy.map(personal),
      'https://cdn.gh-proxy.org/$personal',
    );
  });

  test('ghfast prefixes the whole url', () {
    expect(
      RulesMirror.ghfast.map(official),
      'https://ghfast.top/$official',
    );
  });

  test('gitcode only rewrites the official repo', () {
    expect(
      RulesMirror.gitcode.map(official),
      'https://raw.gitcode.com/gh_mirrors/ka/KazumiRules/raw/main/index.json',
    );
    expect(
      RulesMirror.gitcode.map(personal),
      'https://cdn.gh-proxy.org/$personal',
    );
  });

  test('direct leaves built-ins alone', () {
    expect(RulesMirror.direct.map(official), isNull);
    expect(RulesMirror.direct.map(personal), isNull);
  });

  test('third party repositories are never rewritten', () {
    for (final mode in RulesMirror.values) {
      expect(mode.map(third), isNull, reason: mode.name);
    }
  });
}
