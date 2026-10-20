import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';
import 'package:kazumi/modules/plugin/rule_repository.dart';
import 'package:kazumi/pages/plugin_editor/rule_repository_page.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/request/config/rules_repository_config.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getTemporaryPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => path;
}

/// Catalog stub serving one rule per repository, named after its host.
PluginsController buildController({Set<String> failing = const {}}) {
  return PluginsController(
    repositoryCatalogLoader: (repositoryUrl) async {
      final host = Uri.parse(repositoryUrl).host;
      if (failing.contains(host)) {
        throw StateError('unreachable');
      }
      return <PluginHTTPItem>[
        PluginHTTPItem(
          name: 'rule-$host',
          version: '1.0.0',
          useNativePlayer: false,
          author: 'test',
          lastUpdate: 0,
        ).withRepository(url: repositoryUrl, label: host),
      ];
    },
    repositoryLoader: (repositoryUrl, name) async =>
        throw StateError('not used: this test never downloads a rule'),
  );
}

/// Renders the page after seeding the aggregated catalog.
Future<void> pumpPage(WidgetTester tester, PluginsController controller) async {
  // The controller's loaders are synchronous stubs, but every load still hops
  // through a microtask; pumping flushes those inside the test's fake async
  // zone. Never `tester.runAsync` here: the pending microtasks of the page's
  // own post-frame refresh would then be stranded outside that zone.
  unawaited(controller.refreshPluginCatalog());
  await tester.pumpWidget(MaterialApp(
    home: RuleRepositoryPage(controller: controller),
  ));
  await tester.pump();
  await tester.pumpAndSettle();
}

/// Writes the repository configuration.
///
/// [GStorage.putSetting] awaits a real Hive write, which never completes inside
/// a `testWidgets` fake-async zone, so the write has to run in [tester.runAsync].
Future<T> store<T>(WidgetTester tester, Future<T> Function() write) async {
  final result = await tester.runAsync(write);
  return result as T;
}

void main() {
  late Directory directory;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('kazumi_rules_repo_page_');
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

  testWidgets('lists the official repository with its address and rule count',
      (tester) async {
    await pumpPage(tester, buildController());

    expect(find.text('官方规则仓库'), findsOneWidget);
    expect(find.text('个人规则仓库'), findsOneWidget);
    // The scheme is stripped so long addresses stay readable in one line. Both
    // built-ins live on the same raw host.
    expect(find.textContaining('raw.githubusercontent.com'), findsNWidgets(2));
    expect(find.text('1 条规则'), findsOneWidget);
  });

  testWidgets('the official repository cannot be dragged or deleted',
      (tester) async {
    await pumpPage(tester, buildController());

    // Both built-ins are pinned to the front, so neither renders a drag handle.
    expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);

    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsNothing);
  });

  testWidgets('the personal repository cannot be dragged or deleted',
      (tester) async {
    await pumpPage(tester, buildController());

    await tester.tap(find.byIcon(Icons.more_vert_rounded).last);
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsNothing);
  });

  testWidgets('a third-party repository offers delete and a drag handle',
      (tester) async {
    await store(
      tester,
      () => RulesRepositoryConfig.add(
        const RuleRepository(url: 'https://rules.example.com/'),
      ),
    );
    await pumpPage(tester, buildController());

    expect(find.text('rules.example.com'), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert_rounded).last);
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('a disabled repository reads as closed and loses its count',
      (tester) async {
    await store(
      tester,
      () => RulesRepositoryConfig.add(
        const RuleRepository(
          url: 'https://rules.example.com/',
          enabled: false,
        ),
      ),
    );
    await pumpPage(tester, buildController());

    expect(find.text('已关闭'), findsOneWidget);
    expect(find.text('1 条规则'), findsOneWidget); // official still counts
  });

  testWidgets('an unreachable repository reads as unavailable', (tester) async {
    await store(
      tester,
      () => RulesRepositoryConfig.add(
        const RuleRepository(url: 'https://rules.example.com/'),
      ),
    );
    await pumpPage(tester, buildController(failing: {'rules.example.com'}));

    expect(find.text('无法访问'), findsOneWidget);
  });

  testWidgets('an empty stored list falls back to the official repository',
      (tester) async {
    // `[]` and '' both mean "never configured", so the page always has at least
    // the official repository to show and never renders an empty state.
    await store(tester, () => RulesRepositoryConfig.save(const []));
    await pumpPage(tester, buildController());

    expect(find.text('官方规则仓库'), findsOneWidget);
    expect(find.text('添加规则仓库'), findsNothing);
  });
}
