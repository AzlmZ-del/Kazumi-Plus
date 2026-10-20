import 'dart:io';
import 'dart:convert';
import 'package:mobx/mobx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/plugin/plugin_validity_tracker.dart';
import 'package:kazumi/request/apis/plugin_catalog_api.dart';
import 'package:kazumi/request/config/rules_repository_config.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';
import 'package:kazumi/modules/plugin/rule_repository.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:kazumi/utils/async_single_flight.dart';
import 'package:kazumi/utils/version.dart';

part 'plugins_controller.g.dart';

class PluginsController = _PluginsController with _$PluginsController;

enum PluginUpdateAvailability { unknown, notInCatalog, latest, updatable }

enum PluginCatalogItemStatus { install, installed, update }

enum PluginUpdateResult { updated, requiresNewerClient, failed, notNewer }

class PluginBatchUpdateResult {
  const PluginBatchUpdateResult({
    required this.candidates,
    required this.updated,
    required this.requiresNewerClient,
    required this.failed,
    required this.notNewer,
  });

  final int candidates;
  final int updated;
  final int requiresNewerClient;
  final int failed;
  final int notNewer;

  bool get hasNoCandidates => candidates == 0;
}

/// Loads the whole catalog from a single injected source.
///
/// This replaces catalog aggregation entirely: when it is supplied the
/// controller never reads repository settings. Tests and embedded callers use
/// it to describe "one catalog, period", which the per-repository loaders
/// below cannot express.
typedef PluginCatalogLoader = Future<List<PluginHTTPItem>> Function();
typedef PluginLoader = Future<Plugin> Function(String name);

/// Loads the catalog of one repository.
typedef PluginRepositoryCatalogLoader =
    Future<List<PluginHTTPItem>> Function(String repositoryUrl);

/// Loads a single rule from the repository that advertised it.
typedef PluginRepositoryLoader =
    Future<Plugin> Function(String repositoryUrl, String name);

typedef PluginJsonWriter = Future<void> Function(String jsonData);
typedef PluginErrorReporter = void Function(
  String message,
  Object error,
  StackTrace stackTrace,
);
typedef _PluginUpdateAttempt = ({PluginUpdateResult result, Plugin? plugin});
typedef _RepositoryLoad = ({
  RuleRepository repository,
  List<PluginHTTPItem> items,
  Object? error,
});

/// A repository that could not be read during the last catalog refresh.
///
/// Kept around so the catalog view can explain *why* rules are missing instead
/// of silently showing a shorter list.
class RuleRepositoryFailure {
  const RuleRepositoryFailure({
    required this.repositoryUrl,
    required this.repositoryLabel,
    required this.error,
  });

  final String repositoryUrl;
  final String repositoryLabel;
  final Object error;
}

void _defaultPluginErrorReporter(
  String message,
  Object error,
  StackTrace stackTrace,
) {
  KazumiLogger().e(message, error: error, stackTrace: stackTrace);
}

abstract class _PluginsController with Store {
  _PluginsController({
    PluginCatalogLoader? catalogLoader,
    PluginLoader? pluginLoader,
    PluginRepositoryCatalogLoader? repositoryCatalogLoader,
    PluginRepositoryLoader? repositoryLoader,
    PluginJsonWriter? pluginJsonWriter,
    PluginErrorReporter? errorReporter,
  })  : _catalogLoader = catalogLoader,
        _pluginLoader = pluginLoader,
        _repositoryCatalogLoader =
            repositoryCatalogLoader ?? PluginCatalogApi.getPluginListFrom,
        _repositoryLoader =
            repositoryLoader ?? PluginCatalogApi.getPluginFromRepository,
        _pluginJsonWriter = pluginJsonWriter,
        _errorReporter = errorReporter ?? _defaultPluginErrorReporter;

  /// Whole-catalog override; bypasses repository aggregation when set.
  final PluginCatalogLoader? _catalogLoader;

  /// Whole-catalog single-rule override; bypasses per-repository routing.
  final PluginLoader? _pluginLoader;

  final PluginRepositoryCatalogLoader _repositoryCatalogLoader;
  final PluginRepositoryLoader _repositoryLoader;
  final PluginJsonWriter? _pluginJsonWriter;
  final PluginErrorReporter _errorReporter;
  final AsyncSingleFlight<List<PluginHTTPItem>> _catalogRefreshSingleFlight =
      AsyncSingleFlight<List<PluginHTTPItem>>();
  final AsyncSerialQueue _mutations = AsyncSerialQueue();
  Map<String, PluginHTTPItem> _pluginCatalogByName = const {};
  DateTime? _pluginCatalogRefreshedAt;

  /// Rules hidden behind a same-named rule from an earlier repository.
  ///
  /// Keyed by the winning name's [pluginNameKey]; the values are the shadowed
  /// items in repository order, so the UI can show "+2" and offer a picker
  /// without re-reading settings.
  Map<String, List<PluginHTTPItem>> _shadowedRules = const {};
  List<RuleRepositoryFailure> _repositoryFailures = const [];

  /// Bumped whenever the repository configuration changes.
  ///
  /// An in-flight refresh that started before the bump must discard its result
  /// instead of publishing it, otherwise a slow old request can overwrite the
  /// new configuration's catalog and stamp `_pluginCatalogRefreshedAt`, which
  /// would then serve stale data for [_pluginCatalogMaxAge].
  int _pluginCatalogGeneration = 0;

  int _optimisticReorderRevision = 0;

  // Reuse a recent catalog across startup, the rule list, and the rule shop.
  // Explicit refresh actions always bypass this window.
  static const _pluginCatalogMaxAge = Duration(minutes: 5);
  static const _maxConcurrentRuleDownloads = 4;

  @observable
  ObservableList<Plugin> pluginList = ObservableList.of([]);

  @observable
  ObservableList<PluginHTTPItem> pluginHTTPList = ObservableList.of([]);

  final validityTracker = PluginValidityTracker();

  static const _pluginsFileName = 'plugins.json';
  File? _pluginsFile;

  Future<void> init() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final legacyDirectory = Directory('${supportDirectory.path}/plugins');
    final directory = Directory('${legacyDirectory.path}/v2');
    await directory.create(recursive: true);
    KazumiLogger().i('Plugins Directory: ${directory.path}');
    final pluginsFile = File('${directory.path}/$_pluginsFileName');
    _pluginsFile = pluginsFile;
    pluginList.clear();
    if (await pluginsFile.exists()) {
      final List<dynamic> json = jsonDecode(await pluginsFile.readAsString());
      pluginList.addAll([for (final item in json) Plugin.fromJson(item)]);
      KazumiLogger().i('Plugin: Current Plugin number: ${pluginList.length}');
    } else {
      await _migrateLegacyPlugins(legacyDirectory);
    }
  }

  // Before 1.5.1 each rule was a separate JSON file in the parent directory.
  Future<void> _migrateLegacyPlugins(Directory legacyDirectory) async {
    final legacyFiles = legacyDirectory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'));
    for (final file in legacyFiles) {
      pluginList.add(Plugin.fromJson(jsonDecode(await file.readAsString())));
      await file.delete();
    }
    await _savePlugins();
  }

  List<dynamic> _pluginListToJson() =>
      [for (final plugin in pluginList) plugin.toJson()];

  Future<void> removePlugin(Plugin plugin) {
    return _mutateAndPersist(
      () => pluginList.removeWhere(
        (candidate) =>
            pluginNameKey(candidate.name) == pluginNameKey(plugin.name),
      ),
      errorMessage: 'Plugin: failed to persist rule removal',
    );
  }

  bool get isPluginCatalogFresh {
    final refreshedAt = _pluginCatalogRefreshedAt;
    return refreshedAt != null &&
        DateTime.now().difference(refreshedAt) < _pluginCatalogMaxAge;
  }

  void _replacePlugin(Plugin plugin) {
    bool flag = false;
    for (int i = 0; i < pluginList.length; ++i) {
      if (pluginNameKey(pluginList[i].name) == pluginNameKey(plugin.name)) {
        pluginList.replaceRange(i, i + 1, [plugin]);
        flag = true;
        break;
      }
    }
    if (!flag) {
      pluginList.add(plugin);
    }
  }

  Future<T> _mutateAndPersist<T>(
    T Function() mutate, {
    required String errorMessage,
  }) {
    return _mutations.run(
      () => _mutateAndPersistNow(
        mutate,
        errorMessage: errorMessage,
      ),
    );
  }

  Future<T> _mutateAndPersistNow<T>(
    T Function() mutate, {
    required String errorMessage,
  }) async {
    final previous = List<Plugin>.from(pluginList);
    try {
      final result = mutate();
      await _savePlugins();
      return result;
    } catch (error, stackTrace) {
      pluginList
        ..clear()
        ..addAll(previous);
      _errorReporter(errorMessage, error, stackTrace);
      rethrow;
    }
  }

  Future<void> updatePlugin(Plugin plugin) {
    return _mutateAndPersist(
      () => _replacePlugin(plugin),
      errorMessage: 'Plugin: failed to persist rule update',
    );
  }

  Future<void> updatePlugins(Iterable<Plugin> plugins) {
    return _mutateAndPersist(
      () {
        for (final plugin in plugins) {
          _replacePlugin(plugin);
        }
      },
      errorMessage: 'Plugin: failed to persist imported rules',
    );
  }

  Future<void> onReorder(int oldIndex, int newIndex) {
    final previous = List<Plugin>.from(pluginList);
    final plugin = pluginList.removeAt(oldIndex);
    pluginList.insert(newIndex, plugin);
    final jsonData = jsonEncode(_pluginListToJson());
    final revision = ++_optimisticReorderRevision;
    return _mutations.run(() async {
      try {
        await _writePluginsJson(jsonData);
      } catch (error, stackTrace) {
        if (revision == _optimisticReorderRevision) {
          pluginList
            ..clear()
            ..addAll(previous);
        }
        _errorReporter(
          'Plugin: failed to persist rule order',
          error,
          stackTrace,
        );
        rethrow;
      }
    });
  }

  Future<void> _savePlugins() async {
    final jsonData = jsonEncode(_pluginListToJson());
    await _writePluginsJson(jsonData);
  }

  Future<void> _writePluginsJson(String jsonData) async {
    final writer = _pluginJsonWriter;
    if (writer != null) {
      await writer(jsonData);
    } else {
      await _pluginsFile!.writeAsString(jsonData);
      KazumiLogger().i('Plugin: updated plugin file $_pluginsFileName');
    }
  }

  /// Drops the cached catalog so the next read re-aggregates every enabled
  /// repository.
  ///
  /// Called whenever the repository list changes. The generation bump makes any
  /// refresh that is already in flight discard its result.
  void invalidatePluginCatalog() {
    _pluginCatalogGeneration++;
    _pluginCatalogRefreshedAt = null;
    _pluginCatalogByName = const {};
    _shadowedRules = const {};
    _repositoryFailures = const [];
    pluginHTTPList.clear();
  }

  Future<List<PluginHTTPItem>> refreshPluginCatalog() {
    return _catalogRefreshSingleFlight.run(() async {
      try {
        return List<PluginHTTPItem>.unmodifiable(await _loadCatalog());
      } catch (error, stackTrace) {
        _errorReporter(
          'Plugin: failed to refresh rule catalog',
          error,
          stackTrace,
        );
        rethrow;
      }
    });
  }

  /// Loads and merges the catalog, retrying if the configuration changed
  /// underneath an in-flight fetch.
  ///
  /// A refresh that started before [invalidatePluginCatalog] must not publish
  /// its result: doing so would both show rules from a repository the user just
  /// disabled *and* stamp `_pluginCatalogRefreshedAt`, which would keep serving
  /// that stale catalog for [_pluginCatalogMaxAge]. Retrying against the new
  /// configuration is cheaper than failing the call, because the caller only
  /// ever wanted "the current catalog".
  Future<List<PluginHTTPItem>> _loadCatalog() async {
    const maxAttempts = 3;
    for (var attempt = 1;; attempt++) {
      final generation = _pluginCatalogGeneration;
      final catalog = await _loadCatalogOnce();
      if (generation == _pluginCatalogGeneration) {
        return catalog;
      }
      if (attempt >= maxAttempts) {
        throw StateError(
          'Rule repository configuration kept changing during catalog refresh',
        );
      }
    }
  }

  /// One aggregation pass over the current configuration.
  ///
  /// Publishes its result; the caller is responsible for generation checking.
  Future<List<PluginHTTPItem>> _loadCatalogOnce() async {
    final wholeCatalogLoader = _catalogLoader;
    if (wholeCatalogLoader != null) {
      final catalog = await wholeCatalogLoader();
      _publishCatalog(catalog, shadowed: const {}, failures: const []);
      return catalog;
    }

    final repositories = RulesRepositoryConfig.enabledRepositories();
    if (repositories.isEmpty) {
      // Every repository was switched off. That is a legal configuration, not
      // an error: there is simply nothing to show.
      _publishCatalog(const [], shadowed: const {}, failures: const []);
      return const [];
    }

    final loads = await Future.wait([
      for (final repository in repositories) _loadOneRepository(repository),
    ]);

    final merged = <String, PluginHTTPItem>{};
    final order = <String>[];
    final shadowed = <String, List<PluginHTTPItem>>{};
    final failures = <RuleRepositoryFailure>[];
    for (final load in loads) {
      if (load.error != null) {
        failures.add(
          RuleRepositoryFailure(
            repositoryUrl: load.repository.url,
            repositoryLabel: load.repository.displayLabel,
            error: load.error!,
          ),
        );
        continue;
      }
      for (final item in load.items) {
        final key = pluginNameKey(item.name);
        final winner = merged[key];
        if (winner == null) {
          merged[key] = item;
          order.add(key);
        } else {
          // Repository order is the user's priority order: the first
          // repository to advertise a name keeps it.
          (shadowed[key] ??= <PluginHTTPItem>[]).add(item);
        }
      }
    }

    if (failures.length == repositories.length) {
      _repositoryFailures = List.unmodifiable(failures);
      throw StateError(
        'None of the ${repositories.length} enabled rule repositories could be '
        'reached: ${failures.map((f) => f.repositoryLabel).join(', ')}',
      );
    }

    final catalog = <PluginHTTPItem>[for (final key in order) merged[key]!];
    _publishCatalog(catalog, shadowed: shadowed, failures: failures);
    return catalog;
  }

  /// Reads one repository, never throwing.
  ///
  /// Callers aggregate with [Future.wait]; a repository that is down or
  /// misconfigured must degrade into a missing section, not a failed refresh.
  Future<_RepositoryLoad> _loadOneRepository(RuleRepository repository) async {
    try {
      final items = await _repositoryCatalogLoader(repository.url);
      // The catalog API cannot know how the user named the repository, so it
      // always tags items with an empty label. Stamp the configured display
      // name here instead: this is the layer that has the setting in hand, and
      // the rule cards read `repositoryLabel` to show where a rule came from.
      final labelled = [
        for (final item in items)
          item.withRepository(
            url: item.repositoryUrl.isEmpty
                ? repository.url
                : item.repositoryUrl,
            label: repository.displayLabel,
          ),
      ];
      return (repository: repository, items: labelled, error: null);
    } catch (error, stackTrace) {
      _errorReporter(
        'Plugin: failed to load rules from ${repository.url}',
        error,
        stackTrace,
      );
      return (
        repository: repository,
        items: const <PluginHTTPItem>[],
        error: error,
      );
    }
  }

  void _publishCatalog(
    List<PluginHTTPItem> catalog, {
    required Map<String, List<PluginHTTPItem>> shadowed,
    required List<RuleRepositoryFailure> failures,
  }) {
    _pluginCatalogByName = {
      for (final item in catalog) pluginNameKey(item.name): item,
    };
    _shadowedRules = {
      for (final entry in shadowed.entries) entry.key: List.unmodifiable(entry.value),
    };
    _repositoryFailures = List.unmodifiable(failures);
    pluginHTTPList
      ..clear()
      ..addAll(catalog);
    _pluginCatalogRefreshedAt = DateTime.now();
  }

  /// Rules that lost the same-name conflict, keyed by the winning name.
  List<PluginHTTPItem> shadowedRulesFor(String name) {
    return _shadowedRules[pluginNameKey(name)] ?? const <PluginHTTPItem>[];
  }

  /// Repositories that failed during the last successful refresh.
  List<RuleRepositoryFailure> get repositoryFailures => _repositoryFailures;

  Future<List<PluginHTTPItem>> ensurePluginCatalog() {
    if (isPluginCatalogFresh) {
      return Future.value(
        List<PluginHTTPItem>.unmodifiable(pluginHTTPList),
      );
    }
    return refreshPluginCatalog();
  }

  Future<int> checkPluginUpdatesOnStartup({required bool enabled}) async {
    if (!enabled) {
      return 0;
    }
    await refreshPluginCatalog();
    return _updatablePlugins().length;
  }

  bool _remoteIsNewer(String localVersion, String remoteVersion) {
    try {
      return needUpdate(localVersion, remoteVersion);
    } catch (_) {
      return localVersion != remoteVersion;
    }
  }

  PluginCatalogItemStatus pluginStatus(PluginHTTPItem pluginHTTPItem) {
    var pluginStatus = PluginCatalogItemStatus.install;
    for (Plugin plugin in pluginList) {
      if (pluginNameKey(pluginHTTPItem.name) == pluginNameKey(plugin.name)) {
        if (_remoteIsNewer(plugin.version, pluginHTTPItem.version)) {
          pluginStatus = PluginCatalogItemStatus.update;
        } else {
          pluginStatus = PluginCatalogItemStatus.installed;
        }
        break;
      }
    }
    return pluginStatus;
  }

  PluginUpdateAvailability pluginUpdateStatus(Plugin plugin) {
    if (_pluginCatalogRefreshedAt == null) {
      return PluginUpdateAvailability.unknown;
    }
    final remote = _pluginCatalogByName[pluginNameKey(plugin.name)];
    if (remote == null) {
      return PluginUpdateAvailability.notInCatalog;
    }
    return _remoteIsNewer(plugin.version, remote.version)
        ? PluginUpdateAvailability.updatable
        : PluginUpdateAvailability.latest;
  }

  /// Catalog entries that have a newer version than the installed rule.
  ///
  /// Returns the catalog items rather than bare names so batch updates know
  /// which repository to download each one from.
  List<PluginHTTPItem> _updatablePlugins() {
    final items = <PluginHTTPItem>[];
    for (final plugin in pluginList) {
      if (pluginUpdateStatus(plugin) != PluginUpdateAvailability.updatable) {
        continue;
      }
      final remote = _pluginCatalogByName[pluginNameKey(plugin.name)];
      if (remote != null) {
        items.add(remote);
      }
    }
    return items;
  }

  Future<PluginUpdateResult> tryUpdatePluginByName(String name) {
    return _mutations.run(() async {
      final catalogItem = _pluginCatalogByName[pluginNameKey(name)];
      final catalogName = catalogItem?.name ?? name;
      final attempt = await _preparePluginUpdate(catalogItem, catalogName);
      if (attempt.result == PluginUpdateResult.updated) {
        await _mutateAndPersistNow(
          () => _replacePlugin(attempt.plugin!),
          errorMessage:
              'Plugin: failed to persist downloaded rule $catalogName',
        );
      }
      return attempt.result;
    });
  }

  /// Downloads [name] from the repository that advertised it.
  ///
  /// [catalogItem] carries that repository. When it is null the rule is not in
  /// any currently enabled catalog, and the official repository is used as a
  /// last resort so an installed rule can still be refreshed directly.
  Future<_PluginUpdateAttempt> _preparePluginUpdate(
    PluginHTTPItem? catalogItem,
    String name,
  ) async {
    late final Plugin remotePlugin;
    try {
      final wholeLoader = _pluginLoader;
      final repositoryUrl = catalogItem?.repositoryUrl ?? '';
      if (wholeLoader != null) {
        remotePlugin = await wholeLoader(name);
      } else if (repositoryUrl.isNotEmpty) {
        remotePlugin = await _repositoryLoader(repositoryUrl, name);
      } else {
        remotePlugin = await _repositoryLoader(
          RuleRepositoryList.officialUrl,
          name,
        );
      }
    } catch (error, stackTrace) {
      _errorReporter(
        'Plugin: failed to download rule $name',
        error,
        stackTrace,
      );
      return (result: PluginUpdateResult.failed, plugin: null);
    }
    // Validate at the injected loader boundary so production and test/custom
    // loaders follow the same integrity rule. Preserve the catalog spelling.
    if (remotePlugin.name.isEmpty ||
        pluginNameKey(remotePlugin.name) != pluginNameKey(name)) {
      final error = FormatException(
        'Downloaded rule name ${remotePlugin.name} does not match $name',
      );
      _errorReporter(
        'Plugin: rejected mismatched rule payload',
        error,
        StackTrace.current,
      );
      return (result: PluginUpdateResult.failed, plugin: null);
    }
    remotePlugin.name = name;
    try {
      if (remotePlugin.requiresNewerClient) {
        return (
          result: PluginUpdateResult.requiresNewerClient,
          plugin: null,
        );
      }
    } catch (error, stackTrace) {
      _errorReporter(
        'Plugin: invalid API level in rule $name',
        error,
        stackTrace,
      );
      return (result: PluginUpdateResult.failed, plugin: null);
    }
    Plugin? local;
    for (final plugin in pluginList) {
      if (pluginNameKey(plugin.name) == pluginNameKey(name)) {
        local = plugin;
        break;
      }
    }
    // Never downgrade an installed plugin; mirrors may lag behind upstream.
    if (local != null && !_remoteIsNewer(local.version, remotePlugin.version)) {
      return (result: PluginUpdateResult.notNewer, plugin: null);
    }
    return (result: PluginUpdateResult.updated, plugin: remotePlugin);
  }

  Future<PluginBatchUpdateResult> tryUpdateAllPlugin({
    bool ensureCatalog = true,
  }) {
    return _mutations.run(
      () => _tryUpdateAllPlugin(ensureCatalog: ensureCatalog),
    );
  }

  Future<PluginBatchUpdateResult> _tryUpdateAllPlugin({
    required bool ensureCatalog,
  }) async {
    if (ensureCatalog) {
      await ensurePluginCatalog();
    } else if (_pluginCatalogRefreshedAt == null) {
      throw StateError('Plugin catalog has not been loaded');
    }

    final candidates = _updatablePlugins();
    final attempts = await _preparePluginUpdates(candidates);
    var updated = 0;
    var requiresNewerClient = 0;
    var failed = 0;
    var notNewer = 0;

    final updatedPlugins = <Plugin>[];
    for (final attempt in attempts) {
      switch (attempt.result) {
        case PluginUpdateResult.updated:
          updated++;
          updatedPlugins.add(attempt.plugin!);
        case PluginUpdateResult.requiresNewerClient:
          requiresNewerClient++;
        case PluginUpdateResult.failed:
          failed++;
        case PluginUpdateResult.notNewer:
          notNewer++;
      }
    }

    if (updatedPlugins.isNotEmpty) {
      await _mutateAndPersistNow(
        () {
          for (final plugin in updatedPlugins) {
            _replacePlugin(plugin);
          }
        },
        errorMessage: 'Plugin: failed to persist batch rule update',
      );
    }
    return PluginBatchUpdateResult(
      candidates: candidates.length,
      updated: updated,
      requiresNewerClient: requiresNewerClient,
      failed: failed,
      notNewer: notNewer,
    );
  }

  Future<List<_PluginUpdateAttempt>> _preparePluginUpdates(
    List<PluginHTTPItem> candidates,
  ) async {
    if (candidates.isEmpty) {
      return const [];
    }
    final results = List<_PluginUpdateAttempt?>.filled(candidates.length, null);
    var nextIndex = 0;

    Future<void> worker() async {
      while (nextIndex < candidates.length) {
        final index = nextIndex++;
        final item = candidates[index];
        results[index] = await _preparePluginUpdate(item, item.name);
      }
    }

    final workerCount = candidates.length < _maxConcurrentRuleDownloads
        ? candidates.length
        : _maxConcurrentRuleDownloads;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    return results.cast<_PluginUpdateAttempt>();
  }

  Future<void> removePlugins(Set<String> pluginNames) {
    final names = Set<String>.of(pluginNames);
    return _mutateAndPersist(
      () {
        for (int i = pluginList.length - 1; i >= 0; --i) {
          var name = pluginList[i].name;
          if (names.contains(name)) {
            pluginList.removeAt(i);
          }
        }
      },
      errorMessage: 'Plugin: failed to persist batch rule removal',
    );
  }
}
