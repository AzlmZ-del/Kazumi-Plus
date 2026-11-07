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

/// 从单个注入源加载整份目录。
///
/// 这会完全取代目录聚合：只要提供了它，控制器就不再读仓库设置。
/// 测试与嵌入式调用方用它表达「就这一份目录」，而下面那套按仓库加载的
/// 实现无法表达这个语义。
typedef PluginCatalogLoader = Future<List<PluginHTTPItem>> Function();
typedef PluginLoader = Future<Plugin> Function(String name);

/// 加载单个仓库的目录。
typedef PluginRepositoryCatalogLoader =
    Future<List<PluginHTTPItem>> Function(String repositoryUrl);

/// 从声明了该规则的仓库加载单条规则。
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

/// 上次目录刷新时读取失败的仓库。
///
/// 留着它是为了让目录视图能解释规则**为什么**少了，
/// 而不是悄悄显示一个更短的列表。
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

  /// 整份目录的覆盖源；设置后就绕过仓库聚合。
  final PluginCatalogLoader? _catalogLoader;

  /// 整份目录下单条规则的覆盖源；设置后就绕过按仓库路由。
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

  /// 被更靠前仓库的同名规则遮住的那些规则。
  ///
  /// 键是胜出者的 [pluginNameKey]；值是按仓库顺序排列的被遮项，
  /// 界面据此显示「+2」并提供选择器，无需再读一次设置。
  Map<String, List<PluginHTTPItem>> _shadowedRules = const {};
  List<RuleRepositoryFailure> _repositoryFailures = const [];

  /// 仓库配置每变更一次就递增。
  ///
  /// 在递增之前发起的刷新必须丢弃结果而不是发布出去，
  /// 否则一个慢的旧请求会覆盖新配置的目录并写上 `_pluginCatalogRefreshedAt`，
  /// 之后 [_pluginCatalogMaxAge] 这段窗口内都会拿到过期数据。
  int _pluginCatalogGeneration = 0;

  int _optimisticReorderRevision = 0;

  // 让启动流程、规则列表与规则商店复用同一份近期目录。
  // 用户显式点刷新时永远绕过这个窗口。
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

  // 1.5.1 之前，每条规则是父目录下的一个独立 JSON 文件。
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

  /// 丢弃缓存目录，让下一次读取重新聚合所有已启用的仓库。
  ///
  /// 仓库列表每次变化都会调用。代际号递增会让已经在途的刷新丢弃其结果。
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

  /// 加载并合并目录；若在拉取途中配置变了就重试。
  ///
  /// 在 [invalidatePluginCatalog] 之前发起的刷新不能发布结果：
  /// 那样既会把用户刚禁用的仓库里的规则显示出来，**又会**写上
  /// `_pluginCatalogRefreshedAt`，导致 [_pluginCatalogMaxAge] 期间
  /// 一直供应这份过期目录。按新配置重试一次，
  /// 比直接让调用失败更划算——调用方要的只是「当前目录」。
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

  /// 对当前配置做一次聚合。
  ///
  /// 负责发布结果；代际校验由调用方自己做。
  Future<List<PluginHTTPItem>> _loadCatalogOnce() async {
    final wholeCatalogLoader = _catalogLoader;
    if (wholeCatalogLoader != null) {
      final catalog = await wholeCatalogLoader();
      _publishCatalog(catalog, shadowed: const {}, failures: const []);
      return catalog;
    }

    final repositories = RulesRepositoryConfig.enabledRepositories();
    if (repositories.isEmpty) {
      // 所有仓库都被关掉了。这是合法配置，不是错误：
      // 只是没有内容可显示而已。
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
          // 仓库顺序就是用户的优先级顺序：
          // 第一个声明了某名字的仓库胜出。
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

  /// 读取单个仓库，且永不抛异常。
  ///
  /// 调用方用 [Future.wait] 聚合；某个仓库挂掉或配置错误，
  /// 只能退化成少一段内容，不能变成整次刷新失败。
  Future<_RepositoryLoad> _loadOneRepository(RuleRepository repository) async {
    try {
      final items = await _repositoryCatalogLoader(repository.url);
      // 目录接口不知道用户给仓库起了什么名字，所以它总是打上空标签。
      // 这里补上配置里的显示名：这一层手上正好有设置，
      // 而规则卡片读 `repositoryLabel` 来显示规则来源。
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

  /// 同名冲突中落败的规则，按胜出者名字索引。
  List<PluginHTTPItem> shadowedRulesFor(String name) {
    return _shadowedRules[pluginNameKey(name)] ?? const <PluginHTTPItem>[];
  }

  /// 上次成功刷新期间读取失败的仓库。
  List<RuleRepositoryFailure> get repositoryFailures => _repositoryFailures;

  /// 目录规则的 `baseURL`，供卡片上的地址行使用。
  ///
  /// 索引文件只带 name/version/author，所以地址只能从规则本身取。
  /// 已安装的那份直接就知道，无需请求即能应答，覆盖了常见情况；
  /// 其余的才去下载
  /// 每个 (仓库, 名称, 版本) 组合只请求一次并缓存（失败也缓存），
  /// 这样滚动列表不会反复冲击仓库。
  final Map<String, Future<String?>> _ruleBaseUrlFutures = {};

  Future<String?> ruleBaseUrl(PluginHTTPItem item) {
    final key = pluginNameKey(item.name);
    for (final plugin in pluginList) {
      if (pluginNameKey(plugin.name) == key &&
          plugin.baseUrl.trim().isNotEmpty) {
        // 和下面的下载一样要缓存：每次 build 都新建 Future，
        // 会让 FutureBuilder 永远处于未完成状态。
        return _ruleBaseUrlFutures.putIfAbsent(
          'installed|$key|${plugin.baseUrl}',
          () => Future.value(plugin.baseUrl),
        );
      }
    }
    final cacheKey = '${item.repositoryUrl}|$key|${item.version}';
    return _ruleBaseUrlFutures.putIfAbsent(cacheKey, () async {
      try {
        final wholeLoader = _pluginLoader;
        final Plugin remote;
        if (wholeLoader != null) {
          remote = await wholeLoader(item.name);
        } else if (item.repositoryUrl.isEmpty) {
          // 无来源标记的条目只会经由整份目录加载器走到这里；
          // 这时去猜官方仓库会变成一次意料之外的请求。
          return null;
        } else {
          remote = await _repositoryLoader(item.repositoryUrl, item.name);
        }
        final baseUrl = remote.baseUrl.trim();
        return baseUrl.isEmpty ? null : baseUrl;
      } catch (error, stackTrace) {
        _errorReporter(
          'Plugin: failed to read the address of rule ${item.name}',
          error,
          stackTrace,
        );
        return null;
      }
    });
  }

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

  /// 版本比已安装规则更新的目录条目。
  ///
  /// 返回目录项而不是裸名字，这样批量更新才知道每一条该去哪个仓库下载。
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

  /// 从声明了 [name] 的仓库下载它。
  ///
  /// [catalogItem] 带着那个仓库。为 null 时说明这条规则不在任何已启用的
  /// 目录里，此时退回官方仓库作为兜底，让已安装的规则仍能直接刷新。
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
    // 在注入加载器的边界上做校验，让生产、测试与自定义加载器
    // 遵循同一套完整性规则。保留目录里的原始拼写。
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
    // 绝不把已安装插件降级；镜像可能落后于上游。
    if (local != null && !_remoteIsNewer(local.version, remotePlugin.version)) {
      return (result: PluginUpdateResult.notNewer, plugin: null);
    }
    // 直连开关合并（用户语义）：
    // - 用户动过开关 → 本地赢，源参数与缺省都不影响
    // - 用户没动过 → 跟随源：源写了 directConnection 用源值；
    //   源没写（缺省）→ 保留本地当前值（本地也没值时保持 false）
    if (local != null) {
      if (local.directConnectionUserOverridden) {
        remotePlugin.directConnection = local.directConnection;
        remotePlugin.directConnectionUserOverridden = true;
      } else if (remotePlugin.directConnectionUnspecified) {
        remotePlugin.directConnection = local.directConnection;
      }
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
