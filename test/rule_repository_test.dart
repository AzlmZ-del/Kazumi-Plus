import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/plugin/rule_repository.dart';
import 'package:kazumi/request/config/api_endpoints.dart';

void main() {
  group('RuleRepository', () {
    test('falls back to the host when no label is set', () {
      const repository = RuleRepository(url: 'https://example.com/rules/');

      expect(repository.displayLabel, 'example.com');
      expect(repository.label, isEmpty);
    });

    test('uses the label when provided', () {
      const repository = RuleRepository(
        url: 'https://example.com/rules/',
        label: '我的镜像',
      );

      expect(repository.displayLabel, '我的镜像');
    });

    test('recognizes the official repository', () {
      expect(
        RuleRepository(url: ApiEndpoints.pluginShop).isOfficial,
        isTrue,
      );
      expect(
        const RuleRepository(url: 'https://example.com/rules/').isOfficial,
        isFalse,
      );
    });

    test('copyWith keeps the url stable', () {
      const repository = RuleRepository(url: 'https://example.com/rules/');
      final renamed = repository.copyWith(label: '镜像');
      final disabled = renamed.copyWith(enabled: false);

      expect(disabled.url, repository.url);
      expect(disabled.label, '镜像');
      expect(disabled.enabled, isFalse);
    });
  });

  group('RuleRepositoryList.defaults', () {
    test('contains only the enabled official repository', () {
      final repositories = RuleRepositoryList.defaults();

      expect(repositories, hasLength(1));
      expect(repositories.single.isOfficial, isTrue);
      expect(repositories.single.enabled, isTrue);
    });
  });

  group('RuleRepositoryList.decode', () {
    test('treats an empty value as never configured', () {
      for (final raw in ['', '   ', '\n']) {
        final repositories = RuleRepositoryList.decode(raw);
        expect(repositories, hasLength(1));
        expect(repositories.single.isOfficial, isTrue);
        expect(repositories.single.enabled, isTrue);
      }
    });

    test('falls back to defaults on malformed JSON', () {
      for (final raw in ['not json', '{}', '[1,2,3]', '"text"']) {
        final repositories = RuleRepositoryList.decode(raw);
        expect(repositories, hasLength(1));
        expect(repositories.single.isOfficial, isTrue);
      }
    });

    test('decodes a round-tripped list', () {
      final source = <RuleRepository>[
        RuleRepository(url: RuleRepositoryList.officialUrl),
        const RuleRepository(
          url: 'https://cdn.example.com/gh/me/Rules/',
          label: '我的镜像',
          enabled: false,
        ),
      ];
      final decoded = RuleRepositoryList.decode(
        RuleRepositoryList.encode(source),
      );

      expect(decoded, source);
    });

    test('keeps enabled state and label of the official repository', () {
      final decoded = RuleRepositoryList.decode(
        jsonEncode([
          {
            'url': RuleRepositoryList.officialUrl,
            'label': '官方（备用）',
            'enabled': false,
          },
        ]),
      );

      expect(decoded, hasLength(1));
      expect(decoded.single.label, '官方（备用）');
      expect(decoded.single.enabled, isFalse);
    });

    test('skips a single corrupt entry instead of dropping everything', () {
      final decoded = RuleRepositoryList.decode(
        jsonEncode([
          {'url': RuleRepositoryList.officialUrl, 'enabled': true},
          'this is not an object',
          {'label': 'missing url'},
          {'url': 'ftp://example.com/rules/', 'enabled': true},
          {'url': 'https://example.com/rules/', 'enabled': true},
        ]),
      );

      expect(decoded, hasLength(2));
      expect(decoded.first.isOfficial, isTrue);
      expect(decoded.last.url, 'https://example.com/rules/');
    });

    test('drops duplicate urls, keeping the first occurrence', () {
      final decoded = RuleRepositoryList.decode(
        jsonEncode([
          {'url': RuleRepositoryList.officialUrl, 'label': 'first'},
          {'url': RuleRepositoryList.officialUrl, 'label': 'second'},
        ]),
      );

      expect(decoded, hasLength(1));
      expect(decoded.single.label, 'first');
    });

    test('defaults missing or non-boolean enabled to true', () {
      final decoded = RuleRepositoryList.decode(
        jsonEncode([
          {'url': 'https://example.com/a/'},
          {'url': 'https://example.com/b/', 'enabled': 'yes'},
        ]),
      );

      // Official is re-inserted at the front, so three entries are expected.
      expect(decoded, hasLength(3));
      expect(decoded.every((repository) => repository.enabled), isTrue);
      expect(decoded.map((repository) => repository.url), [
        RuleRepositoryList.officialUrl,
        'https://example.com/a/',
        'https://example.com/b/',
      ]);
    });

    test('ignores a non-string label', () {
      final decoded = RuleRepositoryList.decode(
        jsonEncode([
          {'url': 'https://example.com/a/', 'label': 42},
        ]),
      );

      expect(decoded.last.label, isEmpty);
    });

    test('moves a displaced official repository back to the front', () {
      final decoded = RuleRepositoryList.decode(
        jsonEncode([
          {'url': 'https://example.com/a/', 'enabled': true},
          {'url': RuleRepositoryList.officialUrl, 'enabled': false},
        ]),
      );

      expect(decoded, hasLength(2));
      expect(decoded.first.isOfficial, isTrue);
      expect(decoded.first.enabled, isFalse);
      expect(decoded.last.url, 'https://example.com/a/');
    });

    test('re-inserts a missing official repository without dropping others',
        () {
      final decoded = RuleRepositoryList.decode(
        jsonEncode([
          {'url': 'https://example.com/a/', 'enabled': true},
        ]),
      );

      expect(decoded, hasLength(2));
      expect(decoded.first.isOfficial, isTrue);
      expect(decoded.first.enabled, isTrue);
      expect(decoded.last.url, 'https://example.com/a/');
    });

    test('keeps every repository disabled when the user turned them all off',
        () {
      final decoded = RuleRepositoryList.decode(
        jsonEncode([
          {'url': RuleRepositoryList.officialUrl, 'enabled': false},
          {'url': 'https://example.com/a/', 'enabled': false},
        ]),
      );

      expect(decoded, hasLength(2));
      expect(decoded.every((repository) => !repository.enabled), isTrue);
    });
  });

  group('RuleRepositoryList.encode', () {
    test('produces a compact JSON array', () {
      final raw = RuleRepositoryList.encode([
        RuleRepository(url: RuleRepositoryList.officialUrl),
        const RuleRepository(url: 'https://example.com/a/', label: 'A'),
      ]);

      final parsed = jsonDecode(raw);
      expect(parsed, isA<List<dynamic>>());
      expect((parsed as List<dynamic>), hasLength(2));
      expect(parsed.first, {
        'url': RuleRepositoryList.officialUrl,
        'label': '',
        'enabled': true,
      });
    });

    test('round-trips an empty list as an empty array', () {
      expect(RuleRepositoryList.encode(const []), '[]');
      // Decoding an empty array restores the defaults rather than yielding an
      // unusable empty repository list.
      expect(RuleRepositoryList.decode('[]'), hasLength(1));
    });
  });
}
