import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';
import 'package:kazumi/modules/plugin/rule_repository.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
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
    directory = await Directory.systemTemp.createTemp(
      'kazumi_plugins_catalog_test_',
    );
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

  group('catalog aggregation', () {
    test('loads the built-in repositories by default', () async {
      final requested = <String>[];
      final controller = _controller(
        catalogLoader: (url) async {
          requested.add(url);
          return [_item('alpha', '1.0')];
        },
      );

      final catalog = await controller.refreshPluginCatalog();

      expect(requested, [
        ApiEndpoints.pluginShop,
        ApiEndpoints.personalPluginShop,
      ]);
      // Both list "alpha", so the earlier built-in keeps it.
      expect(catalog.map((item) => item.name), ['alpha']);
      expect(catalog.single.repositoryUrl, ApiEndpoints.pluginShop);
    });

    test('merges every enabled repository in configured order', () async {
      await RulesRepositoryConfig.save([
        const RuleRepository(url: 'https://a.example.com/rules/'),
        const RuleRepository(url: 'https://b.example.com/rules/'),
      ]);
      final controller = _controller(
        catalogLoader: (url) async => [
          for (final name in _catalogFor(url)) _item(name, '1.0'),
        ],
      );

      final catalog = await controller.refreshPluginCatalog();

      expect(
        catalog.map((item) => item.name),
        ['official', 'alpha', 'beta'],
      );
      expect(
        catalog.map((item) => item.repositoryUrl),
        [
          ApiEndpoints.pluginShop,
          'https://a.example.com/rules/',
          'https://b.example.com/rules/',
        ],
      );
    });

    test('keeps the first repository when two advertise the same name', () async {
      await RulesRepositoryConfig.save([
        const RuleRepository(url: 'https://a.example.com/rules/'),
        const RuleRepository(url: 'https://b.example.com/rules/'),
      ]);
      final controller = _controller(
        catalogLoader: (url) async {
          // Only the two custom repositories advertise "shared"; the official
          // repository stays silent so the conflict is between a and b.
          if (url.contains('a.example.com')) {
            return [_item('shared', '1.0', author: 'a')];
          }
          if (url.contains('b.example.com')) {
            return [
              _item('shared', '2.0', author: 'b'),
              _item('beta', '1.0'),
            ];
          }
          return const [];
        },
      );

      final catalog = await controller.refreshPluginCatalog();

      expect(catalog.map((item) => item.name), ['shared', 'beta']);
      expect(catalog.first.author, 'a');
      expect(catalog.first.version, '1.0');

      final shadowed = controller.shadowedRulesFor('SHARED');
      expect(shadowed, hasLength(1));
      expect(shadowed.single.author, 'b');
      expect(shadowed.single.version, '2.0');
    });

    test('skips disabled repositories entirely', () async {
      await RulesRepositoryConfig.save([
        const RuleRepository(url: 'https://a.example.com/rules/'),
        const RuleRepository(
          url: 'https://b.example.com/rules/',
          enabled: false,
        ),
      ]);
      final requested = <String>[];
      final controller = _controller(
        catalogLoader: (url) async {
          requested.add(url);
          return [_item('alpha', '1.0')];
        },
      );

      await controller.refreshPluginCatalog();

      expect(requested, [
        ApiEndpoints.pluginShop,
        ApiEndpoints.personalPluginShop,
        'https://a.example.com/rules/',
      ]);
    });

    test('returns an empty catalog when every repository is disabled', () async {
      await RulesRepositoryConfig.save([
        const RuleRepository(
          url: ApiEndpoints.pluginShop,
          enabled: false,
        ),
        const RuleRepository(
          url: ApiEndpoints.personalPluginShop,
          enabled: false,
        ),
      ]);
      var calls = 0;
      final controller = _controller(
        catalogLoader: (url) async {
          calls++;
          return [_item('alpha', '1.0')];
        },
      );

      final catalog = await controller.refreshPluginCatalog();

      expect(catalog, isEmpty);
      expect(calls, 0);
      expect(controller.pluginHTTPList, isEmpty);
    });

    test('one unreachable repository does not break the catalog', () async {
      await RulesRepositoryConfig.save([
        const RuleRepository(url: 'https://a.example.com/rules/'),
        const RuleRepository(url: 'https://dead.example.com/rules/'),
      ]);
      final controller = _controller(
        catalogLoader: (url) async {
          if (url.contains('dead')) {
            throw StateError('host unreachable');
          }
          return [_item('alpha', '1.0')];
        },
      );

      final catalog = await controller.refreshPluginCatalog();

      expect(catalog.map((item) => item.name), ['alpha']);
      expect(controller.repositoryFailures, hasLength(1));
      expect(
        controller.repositoryFailures.single.repositoryUrl,
        'https://dead.example.com/rules/',
      );
      expect(controller.isPluginCatalogFresh, isTrue);
    });

    test('throws when no repository could be reached', () async {
      await RulesRepositoryConfig.save([
        const RuleRepository(url: 'https://a.example.com/rules/'),
        const RuleRepository(url: 'https://b.example.com/rules/'),
      ]);
      final controller = _controller(
        catalogLoader: (url) async => throw StateError('down: $url'),
      );

      await expectLater(
        controller.refreshPluginCatalog(),
        throwsA(isA<StateError>()),
      );

      expect(controller.repositoryFailures, hasLength(4));
      expect(controller.isPluginCatalogFresh, isFalse);
      expect(controller.pluginHTTPList, isEmpty);
    });
  });

  group('catalog invalidation', () {
    test('invalidate clears the cached catalog', () async {
      final controller = _controller(
        catalogLoader: (url) async => [_item('alpha', '1.0')],
      );
      await controller.refreshPluginCatalog();
      expect(controller.isPluginCatalogFresh, isTrue);

      controller.invalidatePluginCatalog();

      expect(controller.isPluginCatalogFresh, isFalse);
      expect(controller.pluginHTTPList, isEmpty);
      expect(
        controller.pluginUpdateStatus(_pluginFrom(_item('alpha', '1.0'))),
        PluginUpdateAvailability.unknown,
      );
    });

    test('a refresh that outlived an invalidation retries cleanly', () async {
      await RulesRepositoryConfig.save([
        const RuleRepository(url: 'https://old.example.com/rules/'),
      ]);
      final firstCallStarted = Completer<void>();
      final releaseFirstCall = Completer<void>();
      var customCalls = 0;
      final controller = _controller(
        catalogLoader: (url) async {
          if (url == ApiEndpoints.pluginShop ||
              url == ApiEndpoints.personalPluginShop) {
            return const [];
          }
          customCalls++;
          if (customCalls == 1) {
            firstCallStarted.complete();
            await releaseFirstCall.future;
            return [_item('stale', '1.0')];
          }
          return [_item('fresh', '1.0')];
        },
      );

      final refresh = controller.refreshPluginCatalog();
      await firstCallStarted.future;
      await RulesRepositoryConfig.save([
        const RuleRepository(url: 'https://new.example.com/rules/'),
      ]);
      controller.invalidatePluginCatalog();
      releaseFirstCall.complete();

      final catalog = await refresh;

      expect(customCalls, 2);
      expect(catalog.map((item) => item.name), ['fresh']);
      expect(controller.pluginHTTPList.map((item) => item.name), ['fresh']);
      expect(
        controller.pluginHTTPList.single.repositoryUrl,
        'https://new.example.com/rules/',
      );
    });
  });

  group('update routing', () {
    test('downloads an update from the repository that listed it', () async {
      await RulesRepositoryConfig.save([
        const RuleRepository(url: 'https://a.example.com/rules/'),
      ]);
      final downloads = <String>[];
      final controller = _controller(
        // The built-in repositories stay empty so "alpha" is unambiguously
        // sourced from the custom repository.
        catalogLoader: (url) async => url == ApiEndpoints.pluginShop ||
                url == ApiEndpoints.personalPluginShop
            ? const []
            : [_item('alpha', '2.0')],
        ruleLoader: (url, name) async {
          downloads.add('$url|$name');
          return _pluginFrom(_item(name, '2.0'));
        },
      );
      controller.pluginList.add(_pluginFrom(_item('alpha', '1.0')));
      await controller.refreshPluginCatalog();

      final result = await controller.tryUpdatePluginByName('alpha');

      expect(result, PluginUpdateResult.updated);
      expect(downloads, [
        'https://a.example.com/rules/|alpha',
      ]);
      expect(controller.pluginList.single.version, '2.0');
    });

    test('falls back to the official repository when the rule is not listed',
        () async {
      await RulesRepositoryConfig.save([
        const RuleRepository(url: 'https://a.example.com/rules/'),
      ]);
      final downloads = <String>[];
      final controller = _controller(
        catalogLoader: (url) async => [_item('other', '1.0')],
        ruleLoader: (url, name) async {
          downloads.add('$url|$name');
          return _pluginFrom(_item(name, '2.0'));
        },
      );
      controller.pluginList.add(_pluginFrom(_item('alpha', '1.0')));
      await controller.refreshPluginCatalog();

      await controller.tryUpdatePluginByName('alpha');

      expect(downloads, ['${ApiEndpoints.pluginShop}|alpha']);
    });

    test('a whole-catalog loader overrides repository routing', () async {
      await RulesRepositoryConfig.save([
        const RuleRepository(url: 'https://a.example.com/rules/'),
      ]);
      final routed = <String>[];
      final controller = PluginsController(
        catalogLoader: () async => [_item('alpha', '2.0')],
        pluginLoader: (name) async => _pluginFrom(_item(name, '2.0')),
        repositoryCatalogLoader: (url) async {
          throw StateError('per-repository loader must not be used');
        },
        repositoryLoader: (url, name) async {
          routed.add(url);
          throw StateError('per-repository loader must not be used');
        },
        pluginJsonWriter: (_) async {},
        errorReporter: (_, _, _) {},
      );
      controller.pluginList.add(_pluginFrom(_item('alpha', '1.0')));

      final result = await controller.tryUpdatePluginByName('alpha');

      expect(result, PluginUpdateResult.updated);
      expect(routed, isEmpty);
    });
  });
}

PluginsController _controller({
  required Future<List<PluginHTTPItem>> Function(String url) catalogLoader,
  Future<Plugin> Function(String url, String name)? ruleLoader,
}) {
  return PluginsController(
    // Mirror the production API: every item is tagged with the repository it
    // came from, because that tag is what routes the later download.
    repositoryCatalogLoader: (url) async => [
      for (final item in await catalogLoader(url))
        item.withRepository(url: url, label: Uri.parse(url).host),
    ],
    repositoryLoader: ruleLoader ??
        (url, name) async => _pluginFrom(_item(name, '2.0')),
    pluginJsonWriter: (_) async {},
    errorReporter: (_, _, _) {},
  );
}

List<String> _catalogFor(String url) {
  if (url == ApiEndpoints.pluginShop) {
    return ['official'];
  }
  // The personal repository has no rules in these fixtures, so it stays silent
  // and cannot shadow the custom repositories under test.
  if (url == ApiEndpoints.personalPluginShop) {
    return const [];
  }
  if (url.contains('a.example.com')) {
    return ['alpha'];
  }
  return ['beta'];
}

PluginHTTPItem _item(String name, String version, {String author = 'a'}) {
  return PluginHTTPItem(
    name: name,
    version: version,
    useNativePlayer: true,
    author: author,
    lastUpdate: 0,
  );
}

Plugin _pluginFrom(PluginHTTPItem item) {
  return Plugin.fromJson({
    'api': ApiEndpoints.apiLevel.toString(),
    'type': 'anime',
    'name': item.name,
    'version': item.version,
    'muliSources': true,
    'useWebview': true,
    'useNativePlayer': true,
    'usePost': false,
    'useLegacyParser': false,
    'adBlocker': false,
    'userAgent': '',
    'baseURL': 'https://example.com/',
    'searchURL': 'https://example.com/search?q=@keyword',
    'searchList': '//li',
    'searchName': '//a',
    'searchResult': '//a',
    'chapterRoads': '//ul',
    'chapterResult': '//a',
    'referer': '',
  });
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}
