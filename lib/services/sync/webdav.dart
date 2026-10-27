import 'dart:convert';
import 'dart:io';
import 'package:webdav_client/webdav_client.dart' as webdav;
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/modules/history/history_sync.dart';
import 'package:kazumi/modules/danmaku/danmaku_shield_sync.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_change_module.dart';
import 'package:kazumi/services/sync/history_sync_service.dart';
import 'package:kazumi/services/sync/webdav_remote_file_commit.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:kazumi/utils/async_single_flight.dart';

class WebDav {
  static const String _syncRootPath = '/kazumiSync';
  static const String _historyRootPath = '$_syncRootPath/history';
  static const String _historyChangesPath = '$_historyRootPath/changes';
  static const String _historySnapshotPath = '$_historyRootPath/snapshot.json';
  static const String _danmakuShieldPath = '$_syncRootPath/danmakuShield';
  static const String _credentialsPath = '$_syncRootPath/credentials.json';

  late String webDavURL;
  late String webDavUsername;
  late String webDavPassword;
  late Directory webDavLocalTempDirectory;
  late webdav.Client client;

  bool initialized = false;
  static const Duration _staleRunDirectoryAge = Duration(hours: 24);

  final AsyncSingleFlight<void> _historySyncSingleFlight =
      AsyncSingleFlight<void>();
  final AsyncSerialQueue _webDavOperationQueue = AsyncSerialQueue();
  final WebDavRemoteFileCommitter _remoteFileCommitter =
      const WebDavRemoteFileCommitter();

  bool get isHistorySyncing => _historySyncSingleFlight.isRunning;

  /// 【测试连接】是否正在跑。
  ///
  /// 放在服务层而不是页面里：测试可能跑好几秒，中途切走页面再回来，
  /// 按钮仍要显示「测试中…」。与 `BangumiSyncService.isConnecting` 同思路。
  bool _isPinging = false;
  bool get isPinging => _isPinging;

  /// 上一次【测试连接】的失败原因。成功一次就清空，
  /// 供按钮显示「重试连接」。对应 Bangumi 那边的 `lastError`。
  String? _lastPingError;
  String? get lastPingError => _lastPingError;

  /// 测试当前已保存的配置能不能连上（只读存储里的值，不动输入框草稿）。
  ///
  /// `initialized` 为 false 时走完整 `init()`（顺带建远端目录），
  /// 否则只发一次 `ping` —— 两者都会维护 `isPinging` 状态。
  Future<void> testConnection() async {
    if (_isPinging) return;
    _isPinging = true;
    try {
      if (!initialized) {
        await init();
      } else {
        await ping();
      }
      _lastPingError = null;
    } catch (e) {
      _lastPingError = e.toString();
      rethrow;
    } finally {
      _isPinging = false;
    }
  }

  WebDav._internal();
  static final WebDav _instance = WebDav._internal();
  factory WebDav() => _instance;

  Future<void> init() => _runWebDavExclusive(_init);

  Future<void> _init() async {
    initialized = false;
    var directory = await getApplicationSupportDirectory();
    webDavLocalTempDirectory = Directory('${directory.path}/webdavTemp');
    webDavURL = GStorage.getSetting(SettingsKeys.webDavURL);
    webDavUsername = GStorage.getSetting(SettingsKeys.webDavUsername);
    webDavPassword = GStorage.getSetting(SettingsKeys.webDavPassword);
    if (webDavURL.isEmpty) {
      throw Exception('请先填写WebDAV URL');
    }
    client = webdav.newClient(
      webDavURL,
      user: webDavUsername,
      password: webDavPassword,
      debug: false,
    );
    client.setHeaders({'accept-charset': 'utf-8'});
    client.c.options.contentType = 'application/octet-stream';
    try {
      await client.ping();
      await _ensureRemoteDirectory(_syncRootPath);
      await _ensureLocalTempDirectory();
      initialized = true;
      // 连接成功即清掉上次的失败结论：保存新配置时也走这里，
      // 换过配置之后旧的「重试连接」提示就不该留着。
      _lastPingError = null;
      KazumiLogger().i('WebDav: webDav backup directory ready');
    } catch (e) {
      KazumiLogger().e('WebDav: WebDAV ping failed', error: e);
      _lastPingError = e.toString();
      rethrow;
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (enabled && !initialized) await init();
    // 关闭主开关只停止同步，三个内容开关的选择原样保留：
    // 真正的同步入口都会同时判断 webDavEnable 与各自的内容开关，
    // 所以主开关关着时即使内容开关还亮着也不会发起任何请求。
    await GStorage.putSetting(SettingsKeys.webDavEnable, enabled);
  }

  Future<T> _runWebDavExclusive<T>(Future<T> Function() action) {
    return _webDavOperationQueue.run(action);
  }

  bool get isDanmakuShieldSyncEnabled =>
      GStorage.getSetting(SettingsKeys.webDavEnable) &&
      GStorage.getSetting(SettingsKeys.webDavEnableDanmakuShield);

  Future<void> syncDanmakuShield({
    required String deviceId,
    required Future<DanmakuShieldSyncState> Function(DanmakuShieldSyncState)
    merge,
  }) {
    // Queue every request: an edit during an upload needs another pass.
    return _runWebDavExclusive(() async {
      if (!isDanmakuShieldSyncEnabled) return;
      if (!initialized) await _init();
      await _ensureLocalTempDirectory();
      await _ensureRemoteDirectory(_danmakuShieldPath);
      final runDirectory = await webDavLocalTempDirectory.createTemp(
        'danmaku-shield-sync-',
      );
      try {
        var remote = DanmakuShieldSyncState();
        final entries = await client.readDir(_danmakuShieldPath);
        var index = 0;
        for (final entry in entries) {
          final name = entry.name ?? '';
          if (entry.isDir == true ||
              !RegExp(r'^[0-9a-f]{32}\.json$').hasMatch(name)) {
            continue;
          }
          final file = File('${runDirectory.path}/remote-${index++}.json');
          await client.read2File('$_danmakuShieldPath/$name', file.path);
          remote = remote.merge(
            DanmakuShieldSyncState.decode(await file.readAsString()),
          );
        }
        if (!isDanmakuShieldSyncEnabled) return;
        final merged = await merge(remote);
        final upload = File('${runDirectory.path}/local.json');
        await upload.writeAsString(merged.encode(), flush: true);
        // Per-device files prevent simultaneous uploads from losing edits.
        final destination = '$_danmakuShieldPath/$deviceId.json';
        await _publishRemoteFile(
          sourceFilePath: upload.path,
          destinationPath: destination,
          temporaryPath: '$destination.cache',
        );
      } finally {
        try {
          await runDirectory.delete(recursive: true);
        } catch (e) {
          KazumiLogger().w(
            'WebDav: failed to clean danmaku shield sync files',
            error: e,
          );
        }
      }
    });
  }

  Future<void> _updateBox(String boxName) async {
    var directory = await getApplicationSupportDirectory();
    final localFilePath = '${directory.path}/hive/$boxName.hive';
    final tempFilePath = '${webDavLocalTempDirectory.path}/$boxName.tmp';
    final webDavPath = '$_syncRootPath/$boxName.tmp';
    await File(localFilePath).copy(tempFilePath);
    await _publishRemoteFile(
      sourceFilePath: tempFilePath,
      destinationPath: webDavPath,
      temporaryPath: '$webDavPath.cache',
    );
    try {
      await File(tempFilePath).delete();
    } catch (_) {}
  }

  /// 参与账号信息备份的凭据键。
  ///
  /// 全部明文存于本地 Hive 设置箱（与备份文件一致，不做额外加密，方案 1）。
  /// WebDAV 三项「备份了也帮不了新设备首次连接」（新设备必须先手填才能读到
  /// 云端文件），但留档无害——换服务器/迁移时可以照抄。
  static const List<SettingKey<String>> _credentialKeys = [
    SettingsKeys.bangumiAccessToken,
    SettingsKeys.bangumiWebCookie,
    SettingsKeys.bangumiWebEmail,
    SettingsKeys.bangumiWebPassword,
    SettingsKeys.webDavURL,
    SettingsKeys.webDavUsername,
    SettingsKeys.webDavPassword,
  ];

  /// 本地是否存有任何可备份的凭据。
  ///
  /// 「立即备份」在没有任何凭据时给出明确报错，而不是往云端传一个空壳文件。
  bool get hasAnyCredential => _credentialKeys.any(
    (key) => GStorage.getSetting(key).trim().isNotEmpty,
  );

  /// 把本地凭据快照上传到云端（整文件原子覆盖）。
  ///
  /// 上传的是**当前生效值**的 JSON 快照，不是 Hive 箱文件——
  /// 设置箱里混着几十个无关键，整箱备份会让两台设备互相覆盖设置。
  Future<void> uploadCredentials() {
    return _runWebDavExclusive(() async {
      await _ensureRemoteDirectory(_syncRootPath);
      final payload = <String, Object?>{
        'version': 1,
        'backupAt': DateTime.now().toIso8601String(),
        'credentials': {
          for (final key in _credentialKeys)
            if (GStorage.getSetting(key).trim().isNotEmpty)
              key.name: GStorage.getSetting(key),
        },
      };
      final runFile = File(
        '${webDavLocalTempDirectory.path}/credentials.json',
      );
      final credentialsMap = payload['credentials'] as Map<String, Object?>;
      await runFile.writeAsString(jsonEncode(payload), flush: true);
      await _publishRemoteFile(
        sourceFilePath: runFile.path,
        destinationPath: _credentialsPath,
        temporaryPath: '$_credentialsPath.cache',
      );
      try {
        await runFile.delete();
      } catch (_) {}
      KazumiLogger().i(
        'WebDav: credentials uploaded. keys=${credentialsMap.length}',
      );
    });
  }

  /// 从云端下载凭据快照并回填本地（只覆盖云端有的键）。
  ///
  /// 只写设置箱，不触发任何登录/校验请求——有效性由既有逻辑
  /// （`BangumiWebSession.validate()`、下次同步）自行判定。
  /// 云端没有备份文件时抛异常，由调用方转成用户提示。
  Future<void> restoreCredentials() {
    return _runWebDavExclusive(() async {
      await _ensureRemoteDirectory(_syncRootPath);
      if (!await _remoteEntryExists(_credentialsPath)) {
        throw Exception('云端还没有账号信息备份');
      }
      final runFile = File(
        '${webDavLocalTempDirectory.path}/credentials.json',
      );
      if (await runFile.exists()) {
        await runFile.delete();
      }
      await client.read2File(_credentialsPath, runFile.path);
      final decoded =
          jsonDecode(await runFile.readAsString()) as Map<String, dynamic>;
      final credentials = decoded['credentials'];
      if (credentials is! Map<String, dynamic>) {
        throw Exception('备份文件格式不正确');
      }
      final byName = {
        for (final key in _credentialKeys) key.name: key,
      };
      var restored = 0;
      for (final entry in credentials.entries) {
        final key = byName[entry.key];
        final value = entry.value;
        if (key == null || value is! String) continue;
        await GStorage.putSetting(key, value);
        restored++;
      }
      try {
        await runFile.delete();
      } catch (_) {}
      KazumiLogger().i('WebDav: credentials restored. keys=$restored');
    });
  }

  Future<void> syncHistory() {
    return _historySyncSingleFlight.run(() async {
      try {
        await _runWebDavExclusive(_syncHistory);
      } catch (e) {
        KazumiLogger().e('WebDav: history sync failed', error: e);
        rethrow;
      }
    });
  }

  Future<void> updateCollectibles() async {
    try {
      await _runWebDavExclusive(() async {
        await _updateBox('collectibles');
        if (GStorage.collectChanges.isNotEmpty) {
          await _updateBox('collectchanges');
        }
      });
    } catch (e) {
      KazumiLogger().e('WebDav: update collectibles failed', error: e);
      rethrow;
    }
  }

  Future<void> _downloadBox(String boxName) async {
    String fileName = '$boxName.tmp';
    final existingFile = File('${webDavLocalTempDirectory.path}/$fileName');
    if (await existingFile.exists()) {
      await existingFile.delete();
    }
    await client.read2File('$_syncRootPath/$fileName', existingFile.path);
  }

  Future<void> syncCollectibles() async {
    return _runWebDavExclusive(_syncCollectibles);
  }

  Future<void> _syncCollectibles() async {
    // 设置页的「立即同步收藏列表」可能在任何时刻触发，先确保临时目录存在。
    await _ensureLocalTempDirectory();
    List<CollectedBangumi> remoteCollectibles = [];
    List<CollectedBangumiChange> remoteChanges = [];

    final files = await client.readDir(_syncRootPath);
    final collectiblesExists = files.any(
      (file) => file.name == 'collectibles.tmp',
    );
    final changesExists = files.any(
      (file) => file.name == 'collectchanges.tmp',
    );
    if (!collectiblesExists && !changesExists) {
      await _updateBox('collectibles');
      if (GStorage.collectChanges.isNotEmpty) {
        await _updateBox('collectchanges');
      }
      return;
    }

    List<Future<void>> downloadFutures = [];
    if (collectiblesExists) {
      downloadFutures.add(
        _downloadBox('collectibles').catchError((e) {
          KazumiLogger().e('WebDav: download collectibles failed', error: e);
          throw Exception('WebDav: download collectibles failed');
        }),
      );
    }
    if (changesExists) {
      downloadFutures.add(
        _downloadBox('collectchanges').catchError((e) {
          KazumiLogger().e('WebDav: download collectchanges failed', error: e);
          throw Exception('WebDav: download collectchanges failed');
        }),
      );
    }
    if (downloadFutures.isNotEmpty) {
      await Future.wait(downloadFutures);
    }
    try {
      if (collectiblesExists) {
        remoteCollectibles = await GStorage.getCollectiblesFromFile(
          '${webDavLocalTempDirectory.path}/collectibles.tmp',
        );
      }
      if (changesExists) {
        remoteChanges = await GStorage.getCollectChangesFromFile(
          '${webDavLocalTempDirectory.path}/collectchanges.tmp',
        );
      }
    } catch (e) {
      KazumiLogger().e('WebDav: get collectibles failed', error: e);
      throw Exception('WebDav: get collectibles from file failed');
    }
    if (remoteChanges.isNotEmpty || remoteCollectibles.isNotEmpty) {
      await GStorage.patchCollectibles(remoteCollectibles, remoteChanges);
    }
    await _updateBox('collectibles');
    if (GStorage.collectChanges.isNotEmpty) {
      await _updateBox('collectchanges');
    }
  }

  Future<void> _syncHistory() async {
    await _ensureHistoryStorage();
    final historySync = HistorySyncService();
    final deviceId = await historySync.getDeviceId();
    final runDirectory = await _createHistorySyncRunDirectory();

    try {
      final downloads = await _downloadHistorySyncFiles(
        runDirectory: runDirectory,
        deviceId: deviceId,
      );
      final snapshotReadResult = await _readRemoteHistorySnapshot(
        historySync,
        downloads.snapshotFile,
      );
      var remoteSnapshot = snapshotReadResult.snapshot;
      var importedLegacyHistory = false;

      if (_isEmptyHistorySnapshot(remoteSnapshot) &&
          downloads.eventFiles.isEmpty) {
        importedLegacyHistory = await _tryImportLegacyHistory(runDirectory);
        if (importedLegacyHistory) {
          remoteSnapshot = await historySync.buildSnapshotFromLocal();
        }
      }

      final snapshotInitialized = GStorage.getSetting(
        SettingsKeys.historySyncSnapshotInitialized,
      );
      final localBatch = await historySync.prepareLocalLogs(
        runDirectory: runDirectory,
        forceCheckpoint:
            snapshotInitialized != true ||
            snapshotReadResult.needsRepair ||
            downloads.currentDeviceLogOversized ||
            importedLegacyHistory,
      );
      final mergedRemoteSnapshot = await _mergeRemoteHistoryEventFiles(
        historySync: historySync,
        snapshot: remoteSnapshot,
        eventFiles: downloads.eventFiles,
      );
      // Salvage interrupted local writes; reject malformed remote files as a whole.
      final mergedFromFiles = await historySync.mergeEventFiles(
        snapshot: mergedRemoteSnapshot,
        eventFiles: localBatch.files,
        inMemoryEvents: await historySync.buildLocalStateEvents(),
        tolerateMalformedLines: true,
      );

      final mergedSnapshot = await historySync.reconcileAndApplySnapshot(
        mergedFromFiles,
      );

      if (localBatch.shouldCheckpoint) {
        final snapshotFile = File(
          '${runDirectory.path}${Platform.pathSeparator}snapshot.json',
        );
        await historySync.writeSnapshotFile(mergedSnapshot, snapshotFile);
        await _publishHistorySnapshot(
          snapshotFile: snapshotFile,
          deviceId: deviceId,
        );
        await historySync.completeCheckpoint(localBatch);
        await _removeDeviceHistoryChanges(deviceId);
        await GStorage.putSetting(
          SettingsKeys.historySyncSnapshotInitialized,
          true,
        );
      } else {
        final uploadFile = await historySync.copyActiveLogForUpload(
          runDirectory,
        );
        if (uploadFile != null) {
          await _publishDeviceHistoryChanges(
            sourceFile: uploadFile,
            deviceId: deviceId,
          );
        }
      }
    } finally {
      try {
        if (await runDirectory.exists()) {
          await runDirectory.delete(recursive: true);
        }
      } catch (e) {
        KazumiLogger().w(
          'WebDav: failed to clean history sync temp directory',
          error: e,
        );
      }
    }
  }

  bool _isEmptyHistorySnapshot(HistorySyncSnapshot snapshot) {
    return snapshot.histories.isEmpty &&
        snapshot.itemVersions.isEmpty &&
        snapshot.progressVersions.isEmpty &&
        snapshot.deletedVersions.isEmpty &&
        snapshot.clearVersion == null;
  }

  Future<_HistorySnapshotReadResult> _readRemoteHistorySnapshot(
    HistorySyncService historySync,
    File? snapshotFile,
  ) async {
    if (snapshotFile == null) {
      return _HistorySnapshotReadResult(
        snapshot: HistorySyncSnapshot.empty(),
        needsRepair: false,
      );
    }

    try {
      return _HistorySnapshotReadResult(
        snapshot: await historySync.readSnapshotFile(snapshotFile),
        needsRepair: false,
      );
    } catch (e, stackTrace) {
      KazumiLogger().w(
        'WebDav: invalid history snapshot, rebuilding from event logs',
        error: e,
        stackTrace: stackTrace,
      );
      return _HistorySnapshotReadResult(
        snapshot: HistorySyncSnapshot.empty(),
        needsRepair: true,
      );
    }
  }

  Future<HistorySyncSnapshot> _mergeRemoteHistoryEventFiles({
    required HistorySyncService historySync,
    required HistorySyncSnapshot snapshot,
    required List<_DownloadedHistoryEventFile> eventFiles,
  }) async {
    final eventFilesByPath = {
      for (final eventFile in eventFiles)
        eventFile.localFile.path: eventFile.remoteName,
    };
    return historySync.mergeRemoteEventFiles(
      snapshot: snapshot,
      eventFiles: eventFiles.map((eventFile) => eventFile.localFile),
      onInvalidFile: (file, error, stackTrace) async {
        final remoteName = eventFilesByPath[file.path]!;
        KazumiLogger().w(
          'WebDav: invalid remote history event log $remoteName, skipping',
          error: error,
          stackTrace: stackTrace,
        );
        await _quarantineRemoteHistoryEventFile(remoteName);
      },
    );
  }

  Future<Directory> _createHistorySyncRunDirectory() async {
    await _cleanupStaleHistorySyncRunDirectories();
    return webDavLocalTempDirectory.createTemp('history-sync-run-');
  }

  Future<void> _cleanupStaleHistorySyncRunDirectories() async {
    await _ensureLocalTempDirectory();
    final staleBefore = DateTime.now().subtract(_staleRunDirectoryAge);
    await for (final entity in webDavLocalTempDirectory.list(
      followLinks: false,
    )) {
      if (entity is! Directory) {
        continue;
      }
      final name = entity.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('history-sync-run-')) {
        continue;
      }
      try {
        final stat = await entity.stat();
        // A recent directory may belong to another running Kazumi process.
        if (stat.modified.isAfter(staleBefore)) {
          continue;
        }
        await entity.delete(recursive: true);
      } catch (e) {
        KazumiLogger().w(
          'WebDav: failed to remove stale history sync directory $name',
          error: e,
        );
      }
    }
  }

  Future<_HistorySyncDownloads> _downloadHistorySyncFiles({
    required Directory runDirectory,
    required String deviceId,
  }) async {
    File? snapshotFile;
    final historyEntries = await client.readDir(_historyRootPath);
    final hasSnapshot = historyEntries.any(
      (file) => file.name == 'snapshot.json',
    );
    if (hasSnapshot) {
      snapshotFile = File(
        '${runDirectory.path}${Platform.pathSeparator}remote-snapshot.json',
      );
      await client.read2File(_historySnapshotPath, snapshotFile.path);
    }

    final eventFiles = <_DownloadedHistoryEventFile>[];
    var currentDeviceLogOversized = false;
    final changeEntries = await client.readDir(_historyChangesPath);
    var index = 0;
    for (final entry in changeEntries) {
      final name = entry.name ?? '';
      if (!name.endsWith('.jsonl') || entry.size == 0) {
        continue;
      }
      final localFile = File(
        '${runDirectory.path}${Platform.pathSeparator}'
        'remote-events-${index++}.jsonl',
      );
      await client.read2File('$_historyChangesPath/$name', localFile.path);
      if (name == '$deviceId.jsonl' &&
          await localFile.length() >
              HistorySyncService.checkpointLogThresholdBytes) {
        currentDeviceLogOversized = true;
      }
      eventFiles.add(
        _DownloadedHistoryEventFile(remoteName: name, localFile: localFile),
      );
    }

    return _HistorySyncDownloads(
      snapshotFile: snapshotFile,
      eventFiles: eventFiles,
      currentDeviceLogOversized: currentDeviceLogOversized,
    );
  }

  Future<void> _publishHistorySnapshot({
    required File snapshotFile,
    required String deviceId,
  }) {
    return _publishRemoteFile(
      sourceFilePath: snapshotFile.path,
      destinationPath: _historySnapshotPath,
      temporaryPath: '$_historySnapshotPath.$deviceId.cache',
    );
  }

  Future<void> _publishDeviceHistoryChanges({
    required File sourceFile,
    required String deviceId,
  }) {
    final destinationPath = '$_historyChangesPath/$deviceId.jsonl';
    return _publishRemoteFile(
      sourceFilePath: sourceFile.path,
      destinationPath: destinationPath,
      temporaryPath: '$destinationPath.cache',
    );
  }

  Future<void> _publishRemoteFile({
    required String sourceFilePath,
    required String destinationPath,
    required String temporaryPath,
  }) async {
    await _remoteFileCommitter.replaceFile(
      sourceFilePath: sourceFilePath,
      temporaryPath: temporaryPath,
      destinationPath: destinationPath,
      remove: (path) => client.remove(path),
      uploadFromFile: (sourceFilePath, remotePath) =>
          client.writeFromFile(sourceFilePath, remotePath),
      rename: (sourcePath, targetPath) =>
          client.rename(sourcePath, targetPath, true),
      exists: _remoteEntryExists,
    );
  }

  Future<void> _removeDeviceHistoryChanges(String deviceId) async {
    final remotePath = '$_historyChangesPath/$deviceId.jsonl';
    try {
      await client.remove(remotePath);
    } catch (e) {
      KazumiLogger().w(
        'WebDav: failed to remove checkpointed device history log',
        error: e,
      );
    }
  }

  Future<void> _quarantineRemoteHistoryEventFile(String remoteName) {
    final sourcePath = '$_historyChangesPath/$remoteName';
    final quarantinePath =
        '$sourcePath.invalid.'
        '${DateTime.now().millisecondsSinceEpoch}';
    return _quarantineRemoteFile(
      sourcePath: sourcePath,
      quarantinePath: quarantinePath,
      description: 'history event log $remoteName',
    );
  }

  Future<void> _ensureHistoryStorage() async {
    await _ensureLocalTempDirectory();
    await _ensureRemoteDirectory(_syncRootPath);
    await _ensureRemoteDirectory(_historyRootPath);
    await _ensureRemoteDirectory(_historyChangesPath);
  }

  Future<void> _ensureLocalTempDirectory() async {
    if (!await webDavLocalTempDirectory.exists()) {
      await webDavLocalTempDirectory.create(recursive: true);
    }
  }

  Future<void> _ensureRemoteDirectory(String path) async {
    try {
      await client.mkdir(path);
    } catch (e) {
      if (!await _remoteEntryExists(path)) {
        rethrow;
      }
    }
  }

  Future<bool> _remoteEntryExists(String path) async {
    final normalized = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final index = normalized.lastIndexOf('/');
    final parent = index <= 0 ? '/' : normalized.substring(0, index);
    final name = normalized.substring(index + 1);
    try {
      final files = await client.readDir(parent);
      return files.any((file) => file.name == name);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _tryImportLegacyHistory(Directory runDirectory) async {
    final syncEntries = await client.readDir(_syncRootPath);
    if (!syncEntries.any((file) => file.name == 'histories.tmp')) {
      return false;
    }

    const fileName = 'histories.tmp';
    final existingFile = File(
      '${runDirectory.path}${Platform.pathSeparator}$fileName',
    );
    try {
      await client.read2File('$_syncRootPath/$fileName', existingFile.path);
    } catch (e, stackTrace) {
      KazumiLogger().w(
        'WebDav: failed to download legacy history backup, skipping import',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }

    try {
      await GStorage.patchHistory(existingFile.path);
      KazumiLogger().i('WebDav: imported legacy history backup');
      return true;
    } catch (e, stackTrace) {
      KazumiLogger().w(
        'WebDav: invalid legacy history backup, skipping import',
        error: e,
        stackTrace: stackTrace,
      );
      await _quarantineLegacyHistoryBackup();
      return false;
    }
  }

  Future<void> _quarantineLegacyHistoryBackup() async {
    final quarantinePath =
        '$_syncRootPath/histories.invalid.'
        '${DateTime.now().millisecondsSinceEpoch}.tmp';
    await _quarantineRemoteFile(
      sourcePath: '$_syncRootPath/histories.tmp',
      quarantinePath: quarantinePath,
      description: 'legacy history backup',
    );
  }

  Future<void> _quarantineRemoteFile({
    required String sourcePath,
    required String quarantinePath,
    required String description,
  }) async {
    try {
      await client.rename(sourcePath, quarantinePath, false);
      KazumiLogger().w('WebDav: moved invalid $description to $quarantinePath');
    } catch (e, stackTrace) {
      KazumiLogger().w(
        'WebDav: failed to quarantine invalid $description',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> ping() async {
    try {
      await client.ping();
    } catch (e) {
      KazumiLogger().e('WebDav: WebDav ping failed', error: e);
      rethrow;
    }
  }
}

class _HistorySyncDownloads {
  const _HistorySyncDownloads({
    required this.snapshotFile,
    required this.eventFiles,
    required this.currentDeviceLogOversized,
  });

  final File? snapshotFile;
  final List<_DownloadedHistoryEventFile> eventFiles;
  final bool currentDeviceLogOversized;
}

class _DownloadedHistoryEventFile {
  const _DownloadedHistoryEventFile({
    required this.remoteName,
    required this.localFile,
  });

  final String remoteName;
  final File localFile;
}

class _HistorySnapshotReadResult {
  const _HistorySnapshotReadResult({
    required this.snapshot,
    required this.needsRepair,
  });

  final HistorySyncSnapshot snapshot;
  final bool needsRepair;
}
