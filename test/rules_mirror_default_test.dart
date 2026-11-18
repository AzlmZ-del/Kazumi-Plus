import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/network/rules_mirror.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  late Directory dir;
  late PathProviderPlatform original;

  setUpAll(() async {
    final root = await Directory('tmp').create(recursive: true);
    dir = await root.createTemp('kazumi_rules_mirror_default_');
    original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(dir.path);
    Hive.init(dir.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = original;
    await dir.delete(recursive: true);
  });

  setUp(() async {
    // 每个用例从「从未配置过」开始。
    await GStorage.putSetting(SettingsKeys.rulesMirror, '');
  });

  test('fresh install defaults to GitHub direct', () {
    expect(RulesMirror.current, RulesMirror.direct);
    expect(RulesMirror.current.label, 'GitHub');
  });

  test(
    'the legacy enableGitProxy flag no longer overrides the default',
    () async {
      // 旧开关默认为 true；若还参与兜底，会落到已失效的 cdn.gh-proxy.org。
      await GStorage.putSetting(SettingsKeys.enableGitProxy, true);

      expect(RulesMirror.current, RulesMirror.direct);
    },
  );

  test('an explicitly saved mirror still wins', () async {
    await GStorage.putSetting(
      SettingsKeys.rulesMirror,
      RulesMirror.jsDelivr.name,
    );

    expect(RulesMirror.current, RulesMirror.jsDelivr);
  });
}
