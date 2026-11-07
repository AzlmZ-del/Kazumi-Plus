import 'dart:async';
import 'dart:convert';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/request/config/rules_repository_config.dart';
import 'package:kazumi/request/clients/rules_repo_client.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';

class PluginCatalogApi {
  static final RulesRepoClient _client = RulesRepoClient.instance;

  /// 每个仓库的超时上限，目录与单规则拉取共用。
  ///
  /// 共用的 [NetworkConfig] 超时是按自家接口调的；第三方仓库由用户填写，
  /// 可能很慢或已经失效，不能因为其中一个没响应就卡住整轮目录聚合。
  static const Duration repositoryTimeout = Duration(seconds: 15);

  /// 拉取并解析 [repositoryUrl] 的目录。
  ///
  /// 给每个返回项打上 [repositoryUrl]，让后续的安装/更新能回到同一个仓库。
  /// `repositoryLabel` 在这里留空，由聚合控制器从设置里补上。
  static Future<List<PluginHTTPItem>> getPluginListFrom(
    String repositoryUrl, {
    Duration timeout = repositoryTimeout,
  }) async {
    final normalized = RulesRepositoryConfig.baseUri(repositoryUrl);
    final url = RulesRepositoryConfig.catalogUri(normalized);
    final raw = await _client
        .getText(url)
        .timeout(timeout, onTimeout: () => throw TimeoutException(null, timeout));
    final result = parsePluginList(raw);
    if (result.skippedItems > 0) {
      KazumiLogger().w(
        'Plugin: skipped ${result.skippedItems} invalid rule catalog item(s) '
        'in $normalized',
      );
    }
    return [
      for (final item in result.items)
        item.withRepository(url: normalized, label: ''),
    ];
  }

  static PluginCatalogParseResult parsePluginList(String raw) {
    final jsonData = json.decode(raw);
    if (jsonData is! List) {
      throw const FormatException('Rule catalog root must be a JSON array');
    }
    final items = <PluginHTTPItem>[];
    var skippedItems = 0;
    for (var index = 0; index < jsonData.length; index++) {
      try {
        items.add(_parsePluginListItem(jsonData[index], index));
      } on FormatException {
        skippedItems++;
      }
    }
    if (jsonData.isNotEmpty && items.isEmpty) {
      throw const FormatException('Rule catalog contains no valid items');
    }
    return PluginCatalogParseResult(
      items: List.unmodifiable(items),
      skippedItems: skippedItems,
    );
  }

  static PluginHTTPItem _parsePluginListItem(Object? value, int index) {
    if (value is! Map) {
      throw FormatException('Rule catalog item $index must be an object');
    }
    try {
      return PluginHTTPItem.fromJson(Map<String, dynamic>.from(value));
    } catch (error) {
      throw FormatException('Invalid rule catalog item $index: $error');
    }
  }

  /// 从 [repositoryUrl] 拉取名为 [name] 的规则。
  static Future<Plugin> getPluginFromRepository(
    String repositoryUrl,
    String name, {
    Duration timeout = repositoryTimeout,
  }) async {
    final url = RulesRepositoryConfig.ruleUri(
      RulesRepositoryConfig.baseUri(repositoryUrl),
      name,
    );
    final raw = await _client
        .getText(url)
        .timeout(timeout, onTimeout: () => throw TimeoutException(null, timeout));
    final jsonData = json.decode(raw);
    if (jsonData is! Map) {
      throw FormatException('Rule $name must be a JSON object');
    }
    return Plugin.fromJson(Map<String, dynamic>.from(jsonData));
  }
}

class PluginCatalogParseResult {
  const PluginCatalogParseResult({
    required this.items,
    required this.skippedItems,
  });

  final List<PluginHTTPItem> items;
  final int skippedItems;
}
