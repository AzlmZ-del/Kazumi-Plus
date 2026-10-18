import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/plugin/plugin_credentials_store.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.basePath);

  final String basePath;

  @override
  Future<String?> getApplicationSupportPath() async =>
      '$basePath/support';

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '$basePath/documents';

  @override
  Future<String?> getTemporaryPath() async => '$basePath/tmp';

  @override
  Future<String?> getApplicationCachePath() async => '$basePath/cache';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  const pluginName = 'cycani';

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('cred_store_test');
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  setUp(() async {
    Logger.level = Level.off;
    await Hive.deleteBoxFromDisk('pluginCredentials');
    PluginCredentialsStore.instance = PluginCredentialsStore.fresh();
    await PluginCredentialsStore.instance.load();
  });

  group('PluginCredentialsStore', () {
    test('starts empty', () {
      expect(PluginCredentialsStore.instance.hasCredentials(pluginName), isFalse);
      expect(PluginCredentialsStore.instance.usernameFor(pluginName), isNull);
      expect(PluginCredentialsStore.instance.tokenFor(pluginName), isNull);
    });

    test('saves and reads credentials', () async {
      await PluginCredentialsStore.instance
          .saveCredentials('Cycani ', username: ' user ', password: 'pass');
      expect(
          PluginCredentialsStore.instance.hasCredentials('cycani'), isTrue);
      expect(PluginCredentialsStore.instance.usernameFor('CYCANI'), 'user');
      expect(PluginCredentialsStore.instance.passwordFor('cycani'), 'pass');
    });

    test('caches tokens and clears them independently', () async {
      await PluginCredentialsStore.instance
          .saveCredentials(pluginName, username: 'u', password: 'p');
      await PluginCredentialsStore.instance.saveToken(pluginName, 'Bearer t1');
      expect(PluginCredentialsStore.instance.tokenFor(pluginName), 'Bearer t1');

      await PluginCredentialsStore.instance.clearToken(pluginName);
      expect(PluginCredentialsStore.instance.tokenFor(pluginName), isNull);
      expect(
          PluginCredentialsStore.instance.hasCredentials(pluginName), isTrue);
    });

    test('survives a restart (reload from disk)', () async {
      await PluginCredentialsStore.instance
          .saveCredentials(pluginName, username: 'u', password: 'p');
      await PluginCredentialsStore.instance.saveToken(pluginName, 'Bearer t1');

      PluginCredentialsStore.instance = PluginCredentialsStore.fresh();
      await PluginCredentialsStore.instance.load();

      expect(PluginCredentialsStore.instance.usernameFor(pluginName), 'u');
      expect(PluginCredentialsStore.instance.passwordFor(pluginName), 'p');
      expect(PluginCredentialsStore.instance.tokenFor(pluginName), 'Bearer t1');
    });

    test('clearAll removes credentials and token', () async {
      await PluginCredentialsStore.instance
          .saveCredentials(pluginName, username: 'u', password: 'p');
      await PluginCredentialsStore.instance.saveToken(pluginName, 't');

      await PluginCredentialsStore.instance.clearAll(pluginName);

      expect(PluginCredentialsStore.instance.hasCredentials(pluginName), isFalse);
      expect(PluginCredentialsStore.instance.tokenFor(pluginName), isNull);
    });

    test('skips malformed persisted entries', () async {
      final box =
          await Hive.openBox<String>('pluginCredentials');
      await box.put('broken', 'not-json');

      PluginCredentialsStore.instance = PluginCredentialsStore.fresh();
      await PluginCredentialsStore.instance.load();

      expect(PluginCredentialsStore.instance.usernameFor('broken'), isNull);
    });
  });
}
