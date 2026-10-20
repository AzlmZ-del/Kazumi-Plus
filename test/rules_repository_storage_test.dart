import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/plugin/rule_repository.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/config/rules_repository_config.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  late Directory directory;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('kazumi_rules_repo_test_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  setUp(() async {
    await GStorage.putSetting(SettingsKeys.ruleRepositories, '');
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    expect(
      directory.absolute.path.startsWith(Directory.systemTemp.absolute.path),
      isTrue,
    );
    await directory.delete(recursive: true);
  });

  group('RulesRepositoryConfig.repositories', () {
    test('returns the built-in repositories when nothing is stored', () {
      final repositories = RulesRepositoryConfig.repositories();

      expect(repositories, hasLength(2));
      expect(repositories.first.isOfficial, isTrue);
      expect(repositories.last.isPersonal, isTrue);
      expect(repositories.every((repository) => repository.enabled), isTrue);
    });

    test('reads what save() wrote', () async {
      await RulesRepositoryConfig.save([
        RuleRepository(url: ApiEndpoints.pluginShop),
        const RuleRepository(
          url: 'https://example.com/rules/',
          label: '我的镜像',
          enabled: false,
        ),
      ]);

      final repositories = RulesRepositoryConfig.repositories();

      expect(repositories, hasLength(3));
      expect(repositories.last.label, '我的镜像');
      expect(repositories.last.enabled, isFalse);
    });

    test('falls back to defaults when the stored value is corrupt', () async {
      await GStorage.putSetting(SettingsKeys.ruleRepositories, '{{{not json');

      final repositories = RulesRepositoryConfig.repositories();

      expect(repositories, hasLength(2));
      expect(repositories.first.isOfficial, isTrue);
      expect(repositories.last.isPersonal, isTrue);
    });
  });

  group('RulesRepositoryConfig.enabledRepositories', () {
    test('keeps list order and drops disabled entries', () async {
      await RulesRepositoryConfig.save([
        RuleRepository(url: ApiEndpoints.pluginShop, enabled: false),
        RuleRepository(url: ApiEndpoints.personalPluginShop, enabled: false),
        const RuleRepository(url: 'https://a.example/', enabled: true),
        const RuleRepository(url: 'https://b.example/', enabled: false),
        const RuleRepository(url: 'https://c.example/', enabled: true),
      ]);

      final enabled = RulesRepositoryConfig.enabledRepositories();

      expect(enabled.map((repository) => repository.url), [
        'https://a.example/',
        'https://c.example/',
      ]);
    });

    test('returns an empty list when everything is turned off', () async {
      await RulesRepositoryConfig.save([
        RuleRepository(url: ApiEndpoints.pluginShop, enabled: false),
        RuleRepository(url: ApiEndpoints.personalPluginShop, enabled: false),
      ]);

      expect(RulesRepositoryConfig.enabledRepositories(), isEmpty);
    });
  });

  group('RulesRepositoryConfig.add', () {
    test('appends a new repository', () async {
      final updated = await RulesRepositoryConfig.add(
        const RuleRepository(url: 'https://example.com/rules/', label: '镜像'),
      );

      expect(updated, hasLength(3));
      expect(updated.last.url, 'https://example.com/rules/');
      expect(RulesRepositoryConfig.repositories(), updated);
    });

    test('rejects a duplicate url', () async {
      await RulesRepositoryConfig.add(
        const RuleRepository(url: 'https://example.com/rules/'),
      );

      await expectLater(
        RulesRepositoryConfig.add(
          const RuleRepository(
            url: 'https://example.com/rules/',
            label: '同一个地址',
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            '该仓库已存在',
          ),
        ),
      );
    });

    test('does not write anything when adding a duplicate', () async {
      await RulesRepositoryConfig.add(
        const RuleRepository(url: 'https://example.com/rules/'),
      );
      final before = GStorage.getSetting(SettingsKeys.ruleRepositories);

      await expectLater(
        RulesRepositoryConfig.add(
          const RuleRepository(url: 'https://example.com/rules/'),
        ),
        throwsFormatException,
      );

      expect(GStorage.getSetting(SettingsKeys.ruleRepositories), before);
    });
  });

  group('RulesRepositoryConfig.replace', () {
    test('renames in place without changing list order', () async {
      await RulesRepositoryConfig.save([
        RuleRepository(url: ApiEndpoints.pluginShop),
        const RuleRepository(url: 'https://a.example/', label: 'old'),
        const RuleRepository(url: 'https://b.example/'),
      ]);

      final updated = await RulesRepositoryConfig.replace(
        'https://a.example/',
        const RuleRepository(url: 'https://a.example/', label: 'new'),
      );

      expect(updated.map((repository) => repository.url), [
        ApiEndpoints.pluginShop,
        ApiEndpoints.personalPluginShop,
        'https://a.example/',
        'https://b.example/',
      ]);
      expect(updated[2].label, 'new');
    });

    test('rejects a url already used by another entry', () async {
      await RulesRepositoryConfig.save([
        RuleRepository(url: ApiEndpoints.pluginShop),
        const RuleRepository(url: 'https://a.example/'),
        const RuleRepository(url: 'https://b.example/'),
      ]);

      await expectLater(
        RulesRepositoryConfig.replace(
          'https://a.example/',
          const RuleRepository(url: 'https://b.example/'),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            '该仓库已存在',
          ),
        ),
      );
    });

    test('rejects an unknown original url', () async {
      await expectLater(
        RulesRepositoryConfig.replace(
          'https://missing.example/',
          const RuleRepository(url: 'https://missing.example/'),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            '该仓库不存在',
          ),
        ),
      );
    });
  });

  group('RulesRepositoryConfig.remove', () {
    test('removes a third-party repository', () async {
      await RulesRepositoryConfig.save([
        RuleRepository(url: ApiEndpoints.pluginShop),
        const RuleRepository(url: 'https://a.example/'),
      ]);

      final updated = await RulesRepositoryConfig.remove('https://a.example/');

      expect(updated, hasLength(2));
      expect(updated.first.isOfficial, isTrue);
      expect(updated.last.isPersonal, isTrue);
    });

    test('refuses to remove the official repository', () async {
      await expectLater(
        RulesRepositoryConfig.remove(ApiEndpoints.pluginShop),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            '官方仓库不能删除，可以关闭它',
          ),
        ),
      );
    });

    test('refuses to remove the personal repository', () async {
      await expectLater(
        RulesRepositoryConfig.remove(ApiEndpoints.personalPluginShop),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            '个人仓库不能删除，可以关闭它',
          ),
        ),
      );
    });

    test('keeps the built-in repositories present after removing everything else',
        () async {
      await RulesRepositoryConfig.save([
        RuleRepository(url: ApiEndpoints.pluginShop),
        const RuleRepository(url: 'https://a.example/'),
        const RuleRepository(url: 'https://b.example/'),
      ]);

      await RulesRepositoryConfig.remove('https://a.example/');
      final updated = await RulesRepositoryConfig.remove('https://b.example/');

      expect(updated, hasLength(2));
      expect(updated.first.isOfficial, isTrue);
      expect(updated.last.isPersonal, isTrue);
    });
  });
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}
