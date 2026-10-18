import 'dart:async';
import 'dart:convert';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/config/rules_repository_config.dart';
import 'package:kazumi/request/clients/rules_repo_client.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';

class PluginCatalogApi {
  static final RulesRepoClient _client = RulesRepoClient.instance;

  /// Per-repository deadline for both the catalog and single-rule fetch.
  ///
  /// The shared [NetworkConfig] timeout is tuned for first-party endpoints;
  /// third-party repositories are user-supplied and may be slow or dead, and a
  /// single unresponsive one must not stall catalog aggregation.
  static const Duration repositoryTimeout = Duration(seconds: 15);

  /// Fetches the catalog of the official repository.
  static Future<List<PluginHTTPItem>> getPluginList() {
    return getPluginListFrom(ApiEndpoints.pluginShop);
  }

  /// Fetches and parses the catalog of [repositoryUrl].
  ///
  /// Tags every returned item with [repositoryUrl] so later install/update
  /// calls can go back to the same repository. `repositoryLabel` is left empty
  /// here; the aggregating controller fills it in from settings.
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

  /// Fetches a single rule from the official repository.
  static Future<Plugin> getPlugin(String name) {
    return getPluginFromRepository(ApiEndpoints.pluginShop, name);
  }

  /// Fetches rule [name] from [repositoryUrl].
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
