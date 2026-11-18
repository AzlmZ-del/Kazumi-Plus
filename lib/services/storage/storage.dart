import 'dart:async';
import 'dart:io';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/hive_registrar.g.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_change_module.dart';
import 'package:kazumi/modules/collect/collect_sync_merger.dart';
import 'package:kazumi/modules/search/search_history_module.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/storage/history_storage_coordinator.dart';
import 'package:kazumi/services/download/download_path_migration.dart';

import 'package:kazumi/services/storage/settings_keys.dart';
export 'package:kazumi/services/storage/settings_keys.dart';

class GStorage {
  /// 不要再使用 favorites box，它已被 collectibles 取代。
  static late Box<BangumiItem> favorites;
  static late Box<CollectedBangumi> collectibles;
  static late Box<History> histories;
  static late Box<CollectedBangumiChange> collectChanges;
  static late Box<String> shieldList;
  static late final Box<dynamic> _setting;
  static late Box<SearchHistory> searchHistory;
  static late Box<DownloadRecord> downloads;

  /// Hive 目录路径，在 init() 里初始化。
  static String? _hivePath;

  /// 用于串行化写操作的队列。
  static Future<void> _collectChangesWriteQueue = Future.value();

  /// 收藏数据发生变更后的通知钩子。
  ///
  /// 挂在 `appendCollectChange` 这个唯一的写入口上，本地备份之类的旁路
  /// 订阅者不用去改每一个收藏操作，也不会漏掉 Bangumi 云端拉回来的变更。
  /// 回调必须是 fire-and-forget 的轻量函数，真正的重活由订阅者自己排队。
  static void Function()? onCollectChanged;

  /// 下一个可用的 ID。
  static int _nextCollectChangeId = 0;

  /// 标记下一个 ID 是否已初始化过。
  static bool _collectChangeIdInitialized = false;

  /// 保证收藏相关的写入串行执行。
  static Future<T> _runCollectChangesWriteExclusive<T>(
    Future<T> Function() action,
  ) {
    final completer = Completer<T>();
    final previousWrite = _collectChangesWriteQueue;

    _collectChangesWriteQueue = (() async {
      try {
        await previousWrite;
      } catch (_) {}

      try {
        completer.complete(await action());
      } catch (e, stackTrace) {
        completer.completeError(e, stackTrace);
      }
    })();

    return completer.future;
  }

  /// 初始化 ID 生成器。
  static void _initializeNextCollectChangeIdLocked() {
    if (_collectChangeIdInitialized) {
      return;
    }

    var maxExistingId = 0;
    for (final key in collectChanges.keys) {
      if (key is int && key > maxExistingId) {
        maxExistingId = key;
      }
    }

    _nextCollectChangeId = maxExistingId;
    _collectChangeIdInitialized = true;
  }

  /// 为收藏变更生成 ID。
  static int _generateCollectChangeIdLocked() {
    _initializeNextCollectChangeIdLocked();

    final currentSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // 保证新 ID 大于任何已有 ID，否则取当前时间戳。
    var nextId = _nextCollectChangeId < currentSeconds
        ? currentSeconds
        : _nextCollectChangeId + 1;
    while (collectChanges.containsKey(nextId)) {
      nextId++;
    }
    _nextCollectChangeId = nextId;
    return nextId;
  }

  /// 追加一条收藏变更。
  static Future<CollectedBangumiChange> appendCollectChange({
    required int bangumiId,
    required int action,
    required int type,
    int? timestamp,
  }) {
    return _runCollectChangesWriteExclusive(() async {
      final change = CollectedBangumiChange(
        _generateCollectChangeIdLocked(),
        bangumiId,
        action,
        type,
        timestamp ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000),
      );
      await collectChanges.put(change.id, change);
      await collectChanges.flush();
      _notifyCollectChanged();
      return change;
    });
  }

  /// 通知订阅者收藏已变更。回调抛错不能影响写入本身。
  static void _notifyCollectChanged() {
    try {
      onCollectChanged?.call();
    } catch (e) {
      KazumiLogger().w('GStorage: collect change listener failed', error: e);
    }
  }

  /// 用同一条写队列写入收藏项。
  static Future<void> putCollectible(CollectedBangumi collectible) {
    return _runCollectChangesWriteExclusive(() async {
      await collectibles.put(collectible.bangumiItem.id, collectible);
      await collectibles.flush();
    });
  }

  /// 用共享的收藏写队列删除收藏项。
  static Future<void> deleteCollectible(int bangumiId) {
    return _runCollectChangesWriteExclusive(() async {
      await collectibles.delete(bangumiId);
      await collectibles.flush();
    });
  }

  static Future init() async {
    _hivePath = '${(await getApplicationSupportDirectory()).path}/hive';

    Hive.registerAdapters();

    // 打开每个 box，并在数据损坏时自动恢复。
    favorites = await _openBoxSafe<BangumiItem>('favorites');
    collectibles = await _openBoxSafe<CollectedBangumi>('collectibles');
    histories = await _openBoxSafe<History>('histories');
    _setting = await _openBoxSafe<dynamic>('setting');
    collectChanges = await _openBoxSafe<CollectedBangumiChange>(
      'collectchanges',
    );
    shieldList = await _openBoxSafe<String>('shieldList');
    searchHistory = await _openBoxSafe<SearchHistory>('searchHistory');
    downloads = await _openBoxSafe<DownloadRecord>('downloads');
    if (Platform.isIOS) {
      await rebaseIosDownloadPaths(downloads);
    }
  }

  /// 打开一个 Hive box，损坏时自动恢复。
  /// box 一旦损坏就删掉重建一个空的。
  static Future<Box<T>> _openBoxSafe<T>(String boxName) async {
    try {
      return await Hive.openBox<T>(boxName);
    } catch (e) {
      KazumiLogger().e(
        'GStorage: Box "$boxName" corrupted, attempting recovery',
        error: e,
      );

      // 删掉损坏的 box 文件。
      await _deleteBoxFiles(boxName);

      // 再打开一次（会新建一个空 box）。
      try {
        final box = await Hive.openBox<T>(boxName);
        KazumiLogger().i(
          'GStorage: Box "$boxName" recovered successfully (data lost)',
        );
        return box;
      } catch (e2) {
        KazumiLogger().e(
          'GStorage: Failed to recover box "$boxName"',
          error: e2,
        );
        rethrow;
      }
    }
  }

  /// 删除指定 box 名的 Hive 文件。
  static Future<void> _deleteBoxFiles(String boxName) async {
    if (_hivePath == null) return;

    final boxFile = File('$_hivePath/$boxName.hive');
    final lockFile = File('$_hivePath/$boxName.lock');

    try {
      if (await boxFile.exists()) {
        await boxFile.delete();
        KazumiLogger().i('GStorage: Deleted corrupted box file: $boxName.hive');
      }
      if (await lockFile.exists()) {
        await lockFile.delete();
        KazumiLogger().i('GStorage: Deleted lock file: $boxName.lock');
      }
    } catch (e) {
      KazumiLogger().e(
        'GStorage: Failed to delete box files for "$boxName"',
        error: e,
      );
    }
  }

  static Future<void> backupBox(String boxName, String backupFilePath) async {
    final appDocumentDir = await getApplicationSupportDirectory();
    final hiveBoxFile = File('${appDocumentDir.path}/hive/$boxName.hive');
    if (await hiveBoxFile.exists()) {
      await hiveBoxFile.copy(backupFilePath);
      KazumiLogger().i('GStorage: backup success: $backupFilePath');
    } else {
      KazumiLogger().w('GStorage: Hive box does not exist: $boxName');
    }
  }

  static Future<void> patchHistory(String backupFilePath) async {
    final backupFile = File(backupFilePath);
    final backupContent = await backupFile.readAsBytes();
    final tempBox = await Hive.openBox('tempHistoryBox', bytes: backupContent);
    try {
      final tempBoxItems = tempBox.toMap().entries;
      await HistoryStorageCoordinator().run(() async {
        for (final tempBoxItem in tempBoxItems) {
          final tempHistory = tempBoxItem.value as History;
          tempHistory.entryKind = HistoryEntryKind.normalize(
            tempHistory.entryKind,
          );
          final targetKey = tempHistory.key;
          final existing = histories.get(targetKey);
          if (existing == null ||
              existing.lastWatchTime.isBefore(tempHistory.lastWatchTime)) {
            await histories.put(targetKey, tempHistory);
          }
        }
      });
    } finally {
      await tempBox.close();
    }
  }

  static Future<List<CollectedBangumi>> getCollectiblesFromFile(
    String backupFilePath,
  ) async {
    final backupFile = File(backupFilePath);
    final backupContent = await backupFile.readAsBytes();
    final tempBox = await Hive.openBox(
      'tempCollectiblesBox',
      bytes: backupContent,
    );
    final tempBoxItems = tempBox.toMap().entries;
    KazumiLogger().i(
      'WebDav: get collectibles from file. tempCollectiblesBox length ${tempBoxItems.length}',
    );

    final List<CollectedBangumi> collectibles = [];
    for (var tempBoxItem in tempBoxItems) {
      collectibles.add(tempBoxItem.value);
    }
    await tempBox.close();
    return collectibles;
  }

  static Future<List<CollectedBangumiChange>> getCollectChangesFromFile(
    String backupFilePath,
  ) async {
    final backupFile = File(backupFilePath);
    final backupContent = await backupFile.readAsBytes();
    final tempBox = await Hive.openBox(
      'tempCollectChangesBox',
      bytes: backupContent,
    );
    final tempBoxItems = tempBox.toMap().entries;
    KazumiLogger().i(
      'WebDav: get collectChanges from file. tempCollectChangesBox length ${tempBoxItems.length}',
    );

    final List<CollectedBangumiChange> collectChanges = [];
    for (var tempBoxItem in tempBoxItems) {
      collectChanges.add(tempBoxItem.value);
    }
    await tempBox.close();
    return collectChanges;
  }

  static Future<void> patchCollectibles(
    List<CollectedBangumi> remoteCollectibles,
    List<CollectedBangumiChange> remoteChanges,
  ) async {
    await _runCollectChangesWriteExclusive(() async {
      final mergeResult = CollectSyncMerger.mergeWebDav(
        localCollectibles: collectibles.values.toList(),
        localChanges: collectChanges.values.toList(),
        remoteCollectibles: remoteCollectibles,
        remoteChanges: remoteChanges,
      );

      // 更新本地存储。
      await collectibles.clear();
      for (var collect in mergeResult.collectibles) {
        await collectibles.put(collect.bangumiItem.id, collect);
      }
      await collectibles.flush();

      await collectChanges.clear();
      for (var change in mergeResult.changes) {
        await collectChanges.put(change.id, change);
      }
      await collectChanges.flush();

      _collectChangeIdInitialized = false;
      _initializeNextCollectChangeIdLocked();
    });
  }

  static T getSetting<T>(
    SettingKey<T> key, {
    SettingContext context = const SettingContext(),
  }) {
    final defaultValue = key.resolveDefault(context);
    final storedValue = _setting.get(key.name);
    if (storedValue is T) {
      return storedValue;
    }
    return defaultValue;
  }

  static Future<void> putSetting<T>(SettingKey<T> key, T value) async {
    await _setting.put(key.name, value);
  }

  static Stream<void> watchSettings(Iterable<SettingKey<Object?>> keys) {
    final names = keys.map((key) => key.name).toSet();
    return _setting
        .watch()
        .where((event) => names.contains(event.key))
        .map((_) {});
  }

  /// 整箱被替换后的通知（目前只有「从本地恢复设置」会触发）。
  ///
  /// 订阅方要按「设置已整体换掉」重新读一遍，而不是只看单个键的变更事件：
  /// 恢复走的是 clear + putAll，一次性刷进去上百个键，逐键监听接不住。
  static final _settingsReloaded = StreamController<void>.broadcast();

  static Stream<void> get settingsReloaded => _settingsReloaded.stream;

  /// 设置整箱已被替换，通知所有订阅方重新读取。
  static void notifySettingsReloaded() {
    if (!_settingsReloaded.isClosed) {
      _settingsReloaded.add(null);
    }
  }

  static List<String> getStringListSettingByName(
    String key, {
    List<String> defaultValue = const [],
  }) {
    final storedValue = _setting.get(key);
    if (storedValue is List) {
      return storedValue.whereType<String>().toList();
    }
    return defaultValue;
  }

  static Future<void> putStringListSettingByName(
    String key,
    List<String> value,
  ) async {
    await _setting.put(key, value);
  }

  static Future<void> resetSettings(Iterable<SettingKey<Object?>> keys) async {
    await _setting.deleteAll(keys.map((key) => key.name));
    await _setting.flush();
  }

  static Future<void> resetPlayerSettings() async {
    await resetSettings(SettingsKeys.byGroup(SettingGroup.player));
  }

  /// 不参与「设置备份」的键：账号密码、令牌与 WebDAV 口令。
  ///
  /// 设置箱是明文 Hive，整箱导出会把口令原样写进备份文件；这些键另走
  /// `LocalBackupSection.credentials` 的 AES 通道。
  static const Set<String> settingBackupExcludedKeys = {
    'bangumiAccessToken',
    'bangumiWebCookie',
    'bangumiWebEmail',
    'bangumiWebPassword',
    'webDavURL',
    'webDavUsername',
    'webDavPasswd',
  };

  /// Hive 用「小写箱名.hive」做文件名，见 [_boxFilePath]。
  static const String _settingsExportBoxName = 'kazumiSettingsExport';

  static const String _settingsRestoreBoxName = 'kazumiSettingsRestore';

  static String _boxFilePath(String dirPath, String boxName) =>
      '$dirPath/${boxName.toLowerCase()}.hive';

  /// 把设置箱整箱导出到 [filePath]。
  ///
  /// 不能直接复制 `.hive`：主箱运行期一直打开、只追加写，未压缩的内容还不在
  /// 磁盘上，所以走「临时箱 + putAll」再拷文件。
  static Future<void> exportSettingsBox(
    String filePath, {
    Set<String> excludedKeys = settingBackupExcludedKeys,
  }) async {
    await _setting.flush();
    final entries = <dynamic, dynamic>{
      for (final entry in _setting.toMap().entries)
        if (!excludedKeys.contains(entry.key)) entry.key: entry.value,
    };
    final tempDir = await _settingsTempDir();
    try {
      final tempBox = await Hive.openBox(
        _settingsExportBoxName,
        path: tempDir.path,
      );
      try {
        await tempBox.putAll(entries);
        await tempBox.flush();
      } finally {
        await tempBox.close();
      }
      await File(
        _boxFilePath(tempDir.path, _settingsExportBoxName),
      ).copy(filePath);
    } finally {
      await _deleteQuietly(tempDir);
    }
    KazumiLogger().i(
      'GStorage: settings exported. keys=${entries.length} -> $filePath',
    );
  }

  /// 用 [filePath] 里的备份整箱覆盖设置，返回备份里的键数。
  ///
  /// 备份里没有的键会被清掉；[excludedKeys] 例外，既不会从备份写回也不会被清空
  /// —— 否则恢复一次「应用设置」会把刚恢复的凭据一起抹掉。先读完再清空。
  static Future<int> restoreSettingsBox(
    String filePath, {
    Set<String> excludedKeys = settingBackupExcludedKeys,
  }) async {
    final backupFile = File(filePath);
    if (!await backupFile.exists()) {
      throw const FileSystemException('设置备份文件不存在');
    }
    final tempDir = await _settingsTempDir();
    final Map<dynamic, dynamic> entries;
    try {
      // Hive 按目录开箱、文件名取小写箱名，所以备份必须落到这个固定名字上。
      await backupFile.copy(
        _boxFilePath(tempDir.path, _settingsRestoreBoxName),
      );
      final tempBox = await Hive.openBox(
        _settingsRestoreBoxName,
        path: tempDir.path,
      );
      try {
        entries = {
          for (final entry in tempBox.toMap().entries)
            if (!excludedKeys.contains(entry.key)) entry.key: entry.value,
        };
      } finally {
        await tempBox.close();
      }
    } finally {
      await _deleteQuietly(tempDir);
    }
    final merged = mergeSettingsForRestore(
      current: _setting.toMap(),
      backup: entries,
      excludedKeys: excludedKeys,
    );
    await _setting.clear();
    if (merged.isNotEmpty) {
      await _setting.putAll(merged);
    }
    await _setting.flush();
    KazumiLogger().i(
      'GStorage: settings restored. keys=${entries.length} total=${merged.length}',
    );
    // 整箱换过之后逐键监听接不住，让界面自己重新读设置（主题、字号等）。
    notifySettingsReloaded();
    return entries.length;
  }

  /// 算出整箱覆盖后的键值：备份里的非凭据键全量替换，凭据键保留本机当前值。
  ///
  /// 抽成纯函数是为了可测 —— `_setting` 只有 App 启动后才存在。
  static Map<dynamic, dynamic> mergeSettingsForRestore({
    required Map<dynamic, dynamic> current,
    required Map<dynamic, dynamic> backup,
    Set<String> excludedKeys = settingBackupExcludedKeys,
  }) {
    return <dynamic, dynamic>{
      for (final key in excludedKeys)
        if (current.containsKey(key)) key: current[key],
      for (final entry in backup.entries)
        if (!excludedKeys.contains(entry.key)) entry.key: entry.value,
    };
  }

  /// Hive 按目录开箱，临时箱必须与主箱分处不同目录；系统临时区还能避开沙盒限制。
  static Future<Directory> _settingsTempDir() =>
      Directory.systemTemp.createTemp('kazumi-settings-');

  /// 临时目录清理失败不该影响备份结果，只记日志。
  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      KazumiLogger().w('GStorage: failed to remove temp dir', error: e);
    }
  }

  static Future<void> resetDanmakuSettings() async {
    await resetSettings(SettingsKeys.byGroup(SettingGroup.danmaku));
  }

  GStorage._();
}
