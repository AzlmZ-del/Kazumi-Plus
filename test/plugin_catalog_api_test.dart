import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';
import 'package:kazumi/request/apis/plugin_catalog_api.dart';

void main() {
  group('PluginHTTPItem', () {
    test('defaults source fields to empty', () {
      final item = PluginHTTPItem.fromJson(_catalogEntry);

      expect(item.repositoryUrl, isEmpty);
      expect(item.repositoryLabel, isEmpty);
    });

    test('ignores source fields present in the catalog JSON', () {
      final item = PluginHTTPItem.fromJson({
        ..._catalogEntry,
        'repositoryUrl': 'https://evil.example.com/',
        'repositoryLabel': 'evil',
      });

      expect(item.repositoryUrl, isEmpty);
      expect(item.repositoryLabel, isEmpty);
    });

    test('withRepository copies fields and tags the source', () {
      final item = PluginHTTPItem.fromJson(_catalogEntry);
      final tagged = item.withRepository(
        url: 'https://example.com/rules/',
        label: 'example',
      );

      expect(tagged.repositoryUrl, 'https://example.com/rules/');
      expect(tagged.repositoryLabel, 'example');
      expect(tagged.name, item.name);
      expect(tagged.version, item.version);
      expect(tagged.author, item.author);
      expect(tagged.lastUpdate, item.lastUpdate);
      expect(tagged.useNativePlayer, item.useNativePlayer);
      expect(tagged.antiCrawlerEnabled, item.antiCrawlerEnabled);
    });

    test('withRepository leaves the original item untouched', () {
      final item = PluginHTTPItem.fromJson(_catalogEntry);

      final tagged = item.withRepository(
        url: 'https://example.com/rules/',
        label: 'example',
      );

      expect(item.repositoryUrl, isEmpty);
      expect(identical(tagged, item), isFalse);
    });
  });

  group('PluginCatalogApi.parsePluginList', () {
    test('parses entries and loses nothing', () {
      final result = PluginCatalogApi.parsePluginList(
        '[${_encode(_catalogEntry)}]',
      );

      expect(result.items, hasLength(1));
      expect(result.skippedItems, 0);
      expect(result.items.first.name, 'example');
    });

    test('skips invalid entries but keeps valid ones', () {
      final result = PluginCatalogApi.parsePluginList(
        '[{"name":"broken"}, ${_encode(_catalogEntry)}, 42]',
      );

      expect(result.skippedItems, 2);
      expect(result.items, hasLength(1));
      expect(result.items.first.name, 'example');
    });

    test('rejects a catalog whose root is not an array', () {
      expect(
        () => PluginCatalogApi.parsePluginList('{"name":"example"}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a non-empty catalog with no valid entry', () {
      expect(
        () => PluginCatalogApi.parsePluginList('[{"name":"broken"}]'),
        throwsA(isA<FormatException>()),
      );
    });

    test('accepts an empty catalog', () {
      final result = PluginCatalogApi.parsePluginList('[]');

      expect(result.items, isEmpty);
      expect(result.skippedItems, 0);
    });
  });
}

String _encode(Map<String, dynamic> value) {
  return const JsonEncoder().convert(value);
}

final Map<String, dynamic> _catalogEntry = {
  'name': 'example',
  'version': '1.2.3',
  'useNativePlayer': true,
  'author': 'someone',
  'lastUpdate': 1700000000,
  'antiCrawlerConfig': {'enabled': true},
};
