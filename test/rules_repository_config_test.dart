import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/config/rules_repository_config.dart';

void main() {
  group('RulesRepositoryConfig.baseUri accepts directory addresses', () {
    const accepted = <String, String>{
      'https://example.com/rules/': 'https://example.com/rules/',
      'https://example.com/rules': 'https://example.com/rules/',
      'https://example.com/': 'https://example.com/',
      'https://example.com': 'https://example.com/',
      // A file URL is peeled back to its containing directory.
      'https://example.com/rules/index.json':
          'https://example.com/rules/',
      'https://example.com/index.json': 'https://example.com/',
      'https://example.com/rules/some-rule.json':
          'https://example.com/rules/',
      // Version-tagged CDN paths keep the trailing slash and the dot.
      'https://cdn.jsdelivr.net/gh/u/R@1.2.0/':
          'https://cdn.jsdelivr.net/gh/u/R@1.2.0/',
      // A file name with a trailing slash is a directory, so it is kept.
      'https://example.com/rules/index.json/':
          'https://example.com/rules/index.json/',
      // Encoded segments are decoded then re-encoded, not truncated.
      'https://example.com/rules/%69ndex.json':
          'https://example.com/rules/',
      'https://example.com/my%20rules/': 'https://example.com/my%20rules/',
      // Repeated slashes collapse instead of producing empty segments.
      'https://example.com//rules//': 'https://example.com/rules/',
      // Scheme is normalized to lower case.
      'HTTPS://Example.COM/Rules/': 'https://example.com/Rules/',
      // Ports and sub-paths survive.
      'http://example.com:8080/rules/': 'http://example.com:8080/rules/',
      'https://example.com/a/b/c/': 'https://example.com/a/b/c/',
      // The official address stays usable.
      ApiEndpoints.pluginShop: ApiEndpoints.pluginShop,
    };

    accepted.forEach((input, expected) {
      test('$input -> $expected', () {
        expect(RulesRepositoryConfig.baseUri(input), expected);
      });
    });

    test('trims surrounding whitespace', () {
      expect(
        RulesRepositoryConfig.baseUri('  https://example.com/rules/  '),
        'https://example.com/rules/',
      );
    });
  });

  group('RulesRepositoryConfig.baseUri rejects bad addresses', () {
    final rejected = <String, String>{
      '': '请填写仓库地址',
      '   ': '请填写仓库地址',
      'example.com/rules/': '地址需要以 http:// 或 https:// 开头',
      '//example.com/rules/': '地址需要以 http:// 或 https:// 开头',
      'ftp://example.com/rules/': '只支持 http:// 和 https:// 地址',
      'file:///c:/rules/': '只支持 http:// 和 https:// 地址',
      'not a url at all': '地址需要以 http:// 或 https:// 开头',
      'https:///rules/': '地址缺少域名',
      'https://user:pass@example.com/rules/': '地址不能包含用户名或密码',
      'https://user@example.com/rules/': '地址不能包含用户名或密码',
      'https://example.com/rules/?token=1':
          '地址不能包含查询参数（? 之后的内容）',
      'https://example.com/rules/#top': '地址不能包含锚点（# 之后的内容）',
      'https://github.com/me/Rules': 'github.com 页面地址无法直接使用，'
          '请改用 raw.githubusercontent.com 等原始内容地址',
      'https://www.github.com/me/Rules/': 'github.com 页面地址无法直接使用，'
          '请改用 raw.githubusercontent.com 等原始内容地址',
      'https://example.com/${'a' * 2048}/': '仓库地址过长',
    };

    rejected.forEach((input, message) {
      test('rejects ${input.isEmpty ? '<empty>' : input}', () {
        expect(
          () => RulesRepositoryConfig.baseUri(input),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              message,
            ),
          ),
        );
      });
    });

    test('allows raw.githubusercontent.com even though github.com is banned',
        () {
      const raw =
          'https://raw.githubusercontent.com/me/Rules/main/';
      expect(RulesRepositoryConfig.baseUri(raw), raw);
    });

    test('treats a bare host with no path as the repository root', () {
      expect(
        RulesRepositoryConfig.baseUri('https://example.com'),
        'https://example.com/',
      );
    });
  });

  group('URL builders', () {
    test('catalogUri appends index.json', () {
      expect(
        RulesRepositoryConfig.catalogUri('https://example.com/rules/'),
        'https://example.com/rules/index.json',
      );
    });

    test('catalogUri tolerates a missing trailing slash', () {
      expect(
        RulesRepositoryConfig.catalogUri('https://example.com/rules'),
        'https://example.com/rules/index.json',
      );
    });

    test('ruleUri appends the rule file name', () {
      expect(
        RulesRepositoryConfig.ruleUri('https://example.com/rules/', 'DM84'),
        'https://example.com/rules/DM84.json',
      );
    });

    test('official catalog URL matches the pre-existing endpoint', () {
      expect(
        RulesRepositoryConfig.catalogUri(ApiEndpoints.pluginShop),
        '${ApiEndpoints.pluginShop}index.json',
      );
    });
  });
}
