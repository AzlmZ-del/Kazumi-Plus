import 'package:kazumi/plugins/api_auth_config.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiAuthConfig', () {
    test('parses a full login config', () {
      final config = ApiAuthConfig.fromJson(const {
        'login': {
          'method': 'POST',
          'url': 'https://example.com/api/auth/login',
          'bodyType': 'json',
          'body': {'username': '@username', 'password': '@password'},
          'headers': {'X-App-Name': 'demo'},
        },
        'tokenPath': r'$.data.token',
        'headerName': 'Authorization',
        'tokenPrefix': '',
        'refreshOnStatus': [401, 403],
      });

      expect(config.login.method, 'POST');
      expect(config.login.url, 'https://example.com/api/auth/login');
      expect(config.login.bodyType, ApiBodyType.json);
      expect(config.login.headers['X-App-Name'], 'demo');
      expect(config.tokenPath, r'$.data.token');
      expect(config.headerName, 'Authorization');
      expect(config.tokenPrefix, '');
      expect(config.refreshOnStatus, [401, 403]);
    });

    test('falls back to defaults for missing fields', () {
      final config = ApiAuthConfig.fromJson(const {
        'login': {'url': 'https://example.com/login'},
      });

      expect(config.login.method, 'POST');
      expect(config.login.bodyType, ApiBodyType.json);
      // The login body template is the overwhelmingly common shape, and a
      // missing tokenPath would make the rule unrunnable anyway.
      expect(config.tokenPath, r'$.data.token');
      expect(config.headerName, 'Authorization');
      // Empty by default: several sites return tokens that already carry the
      // "Bearer " prefix, and blindly prepending one breaks them.
      expect(config.tokenPrefix, '');
      expect(config.refreshOnStatus, [401]);
    });

    test('refreshOnStatus ignores junk entries', () {
      final config = ApiAuthConfig.fromJson(const {
        'login': {'url': 'https://example.com/login'},
        'refreshOnStatus': [401, 'x', 99, 500.0],
      });

      expect(config.refreshOnStatus, [401, 500]);
    });
  });
}
