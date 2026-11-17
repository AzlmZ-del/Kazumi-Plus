import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/modules/collect/collect_change_module.dart';
import 'package:kazumi/modules/danmaku/danmaku_shield_rule.dart';
import 'package:kazumi/repositories/danmaku_shield_repository.dart';
import 'package:kazumi/services/backup/local_backup_items.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/security/credential_cipher.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:kazumi/utils/file_system.dart';
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';
import 'package:path/path.dart' as path;

/// 本地备份失败的原因，直接拿来当提示文案。
class LocalBackupException implements Exception {
  const LocalBackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一次恢复的结果：成功恢复的条目与目录里没找到备份文件的条目。
///
/// 两者分开返回，页面才能把「已恢复：X」和「未找到：Y」分别说清楚，
/// 而不是只报一句干巴巴的成功。
class LocalBackupRestoreResult {
  const LocalBackupRestoreResult({
    required this.done,
    required this.missing,
    this.requiresRestart = false,
  });

  final List<String> done;
  final List<String> missing;

  /// 恢复里含「应用设置」时为真：主题、语言、字号等已写入，但要重启才全量生效。
  final bool requiresRestart;

  bool get hasMissing => missing.isNotEmpty;

  /// 结果描述（不含「已恢复」前缀，前缀由调用方拼）。
  /// 形如 `观看记录（未找到：收藏列表）`，含设置时再追加重启提示。
  String get detail {
    final restored = done.join('、');
    final base = missing.isEmpty
        ? restored
        : '$restored（未找到：${missing.join('、')}）';
    return requiresRestart ? '$base。设置已还原，重启应用后全部生效' : base;
  }
}

/// 把「多设备同步」页里的几类数据备份到本机目录，或从该目录恢复。
///
/// 与 WebDAV 的分工：那边走网络、靠远端文件做合并；这边只碰本地文件系统，
/// 用来在换机、清数据、降级前留一份快照。备份文件以 `kazumi-` 前缀平铺在
/// 用户选的目录里，文件名见各 `_xxxFileName` 常量。
///
/// 恢复一律走「合并」而不是「覆盖」：本地已有的更新记录、更新的收藏时间
/// 不会被一份旧快照冲掉。
class LocalBackupService {
  LocalBackupService(this._shieldRepository);

  /// 弹幕屏蔽词走仓储而不是直接搬 Hive 箱：`setRule` 会顺带更新同步元数据，
  /// 恢复出来的规则不会被云端旧的删除记录压掉。
  final IDanmakuShieldRepository _shieldRepository;

  /// 凭据那一项的声明，供「保存后自动备份」判断开关用。
  static final LocalBackupItem _credentialsItem = localBackupItems.firstWhere(
    (item) => item.section == LocalBackupSection.credentials,
  );

  /// 与「下载设置」共用同一个原生通道：Android 上直接拿文件路径要先有
  /// 全盘访问权限，这套 `requestStorageAccess` + `pickDirectory` 已经在
  /// 下载目录那边跑通，这里照用即可。
  static const MethodChannel _androidChannel = MethodChannel(
    'com.predidit.kazumi/download_directory',
  );

  final _bookmarks = SecureBookmarks();

  /// 自动备份串行化：收藏、屏蔽词、播放退出可能在同一瞬间触发，
  /// 并发写同一批文件会互相踩，排队跑最稳。
  final AsyncSerialQueue _autoBackupQueue = AsyncSerialQueue();

  /// 自动备份的防抖定时器。短时间内多次变更合并成一次写盘。
  Timer? _autoBackupTimer;

  /// 防抖窗口内累积的待写分区。多次触发各自贡献一项，到期一起写。
  final Set<LocalBackupSection> _pendingSections = <LocalBackupSection>{};

  /// 防抖窗口内出现过「全量」请求（如手动点按钮）：一旦为真就整份写。
  bool _pendingAll = false;

  /// 屏蔽词变更订阅。只在 [start] 之后存在。
  StreamSubscription<DanmakuShieldChange>? _shieldSubscription;

  /// 与 WebDAV 那边一致：改动后等 500ms 再落盘，把连点合并成一次。
  static const Duration _autoBackupDebounce = Duration(milliseconds: 500);

  /// macOS 沙盒下目录授权可能随重启失效，需要先恢复才能读写。
  bool _accessLost = false;

  bool get supportsCustomDirectory =>
      Platform.isAndroid || Platform.isMacOS || Platform.isWindows;

  /// 当前备份目录（空 = 尚未选择）。
  String get directory => supportsCustomDirectory
      ? GStorage.getSetting(SettingsKeys.localBackupDirectory).trim()
      : '';

  bool get configured => directory.isNotEmpty;

  /// 本地备份总开关。关着的时候下面的内容开关与按钮一律不可用。
  bool get enabled => GStorage.getSetting(SettingsKeys.localBackupEnable);

  Future<void> setEnabled(bool value) =>
      GStorage.putSetting(SettingsKeys.localBackupEnable, value);

  /// 挂上「改动即备份」的两个触发源：收藏变更、屏蔽词变更。
  ///
  /// 与 WebDAV 的 `DanmakuShieldSyncService.start()` 同一个位置调用，
  /// 只订阅不主动跑——启动阶段不写盘，等真有改动再落。
  /// 每个触发源只写自己那一项，不带着别的分区一起重写。
  void start() {
    _shieldSubscription ??= _shieldRepository.changes
        .where((change) => change == DanmakuShieldChange.localEdit)
        .listen((_) => scheduleAutoBackup(sections: _shieldOnly));
    GStorage.onCollectChanged = _onCollectChanged;
  }

  static const Set<LocalBackupSection> _shieldOnly = {LocalBackupSection.shield};
  static const Set<LocalBackupSection> _collectOnly = {
    LocalBackupSection.collect,
  };
  static const Set<LocalBackupSection> _credentialsOnly = {
    LocalBackupSection.credentials,
  };

  /// 只备份观看记录。播放页退出时调，别的三项不用跟着重写。
  Future<void> autoBackupHistory() =>
      autoBackup(only: const {LocalBackupSection.history});

  /// 收藏变更回调。存成字段而不是每次传 tear-off，`dispose` 里比对才可靠。
  void _onCollectChanged() => scheduleAutoBackup(sections: _collectOnly);

  /// 防抖后自动备份一次。开关没开、目录没选、内容没选都直接跳过。
  ///
  /// [sections] 指定这次要写哪几项，null 表示全部。防抖窗口内多次触发会
  /// **累加**：收藏和屏蔽词在 500ms 内先后变更，合并成一次写盘、两项都写。
  void scheduleAutoBackup({Set<LocalBackupSection>? sections}) {
    _autoBackupTimer?.cancel();
    if (!_autoBackupReady) {
      _pendingSections.clear();
      _pendingAll = false;
      return;
    }
    if (sections == null) {
      _pendingAll = true;
    } else {
      _pendingSections.addAll(sections);
    }
    _autoBackupTimer = Timer(_autoBackupDebounce, () {
      final only = _pendingAll
          ? null
          : Set<LocalBackupSection>.of(_pendingSections);
      _pendingSections.clear();
      _pendingAll = false;
      unawaited(autoBackup(only: only));
    });
  }

  /// 不能只看 [hasSelection]：只勾「应用设置」时它会为真，自动备份会白跑一趟。
  ///
  /// 不含 `_accessLost`：那次失败可能只是 macOS 重启后授权没恢复，
  /// `restoreAccess()` 有机会修好它，所以判定留给 `autoBackup` 内部。
  bool get _autoBackupReady => enabled && configured && hasAutoBackupSelection;

  bool get hasAutoBackupSelection =>
      localBackupItems.any((item) => item.autoBackup && isSelected(item));

  /// 自动备份入口：静默执行，失败只记日志不打扰用户。
  ///
  /// 与手动 `backup()` 共用同一套写盘逻辑，区别只在错误处理——
  /// 播放退出、后台改收藏这些时机弹 toast 会打断用户，所以这里只落日志。
  ///
  /// [only] 只写指定的分区，null 表示全部。各触发点各传自己那一项，
  /// 避免收藏变一次就把四个文件全重写一遍。
  Future<void> autoBackup({Set<LocalBackupSection>? only}) {
    return _autoBackupQueue.run(() async {
      if (!_autoBackupReady) return;
      // 这次触发的分区里若没有任何勾选项，就没必要进写盘流程（连目录都不碰）。
      final sections = only;
      if (sections != null &&
          !localBackupItems.any(
            (item) =>
                item.autoBackup &&
                sections.contains(item.section) &&
                isSelected(item),
          )) {
        return;
      }
      try {
        await restoreAccess();
        // 授权恢复失败就别写了，`_writeBackup` 也会抛，这里提前挡一下。
        if (_accessLost) return;
        await _writeBackup(skipEmptyBoxes: true, only: only);
        KazumiLogger().i('LocalBackup: auto backup finished. only=$only');
      } catch (e) {
        KazumiLogger().w('LocalBackup: auto backup failed', error: e);
      }
    });
  }

  void dispose() {
    _autoBackupTimer?.cancel();
    _autoBackupTimer = null;
    unawaited(_shieldSubscription?.cancel());
    _shieldSubscription = null;
    if (GStorage.onCollectChanged == _onCollectChanged) {
      GStorage.onCollectChanged = null;
    }
  }

  /// 「凭据保存成功后自动备份」的统一入口，与
  /// `WebDav.autoBackupCredentialsAfterSave` 一一对应。
  ///
  /// 三个保存时机共用：Bangumi Token「验证并保存」、「网页登录」的
  /// 「登录并保存」、WebDAV「保存并测试」。只关心「用户凭据」这一项，
  /// 且本地一个凭据都没有时静默跳过——刚配好服务器还没登录账号属于
  /// 正常状态。调用方一律 fire-and-forget。
  Future<void> autoBackupCredentialsAfterSave() async {
    if (!enabled || !configured) return;
    if (!isSelected(_credentialsItem)) return;
    if (!WebDav().hasAnyCredential) return;
    await autoBackup(only: _credentialsOnly);
  }

  /// 「跟随同步」是否开启：开启时受它管辖的内容项改读【启用 WebDAV】的开关。
  bool get followWebDav =>
      GStorage.getSetting(SettingsKeys.localBackupFollowWebDav);

  /// 声明表里 `webDavKey` 为 null 的项（目前只有「应用设置」）永远只看本地开关。
  bool isSelected(LocalBackupItem item) {
    final key = followWebDav && item.webDavKey != null
        ? item.webDavKey!
        : item.localKey;
    return GStorage.getSetting(key);
  }

  bool get hasSelection => localBackupItems.any(isSelected);

  /// 让用户挑一个目录。取消返回 null，选中的目录写完权限后落盘。
  Future<String?> selectDirectory() async {
    if (!supportsCustomDirectory) {
      throw const LocalBackupException('当前平台不支持手动选择目录');
    }
    final current = directory;
    final selected = await _pickDirectory(current.isEmpty ? null : current);
    if (selected == null || selected.isEmpty) return null;
    await _applyDirectory(selected);
    return selected;
  }

  /// 一次性选目录：只开系统选择器，不改写设置、不留持久授权。
  ///
  /// 给「还没设备份路径，但想直接从某个目录恢复一次」用：用户挑完就用这一次，
  /// 不希望因此把「本地备份路径」改掉。取消返回 null。
  Future<String?> pickDirectoryOnce() async {
    if (!supportsCustomDirectory) {
      throw const LocalBackupException('当前平台不支持手动选择目录');
    }
    final current = directory;
    return _pickDirectory(current.isEmpty ? null : current);
  }

  /// 手动填写的目录路径。返回落盘后的路径。
  ///
  /// 与 [selectDirectory] 的差别只在「路径从哪来」：那边走系统选择器，这边
  /// 收用户手打的字符串。拿到路径之后要做的事一模一样 —— 申请存储权限、
  /// 建目录并试写、留持久授权、存设置 —— 所以两个入口最后都汇到
  /// [_applyDirectory]，避免两套流程各自演化。
  Future<String> setDirectory(String rawPath) async {
    if (!supportsCustomDirectory) {
      throw const LocalBackupException('当前平台不支持手动填写目录');
    }
    final target = _normalizePath(rawPath);
    if (target.isEmpty) {
      throw const LocalBackupException('请填写备份目录的完整路径');
    }
    if (!path.isAbsolute(target)) {
      throw const LocalBackupException(
        '请填写完整路径，例如 /storage/emulated/0/Kazumi',
      );
    }
    await _applyDirectory(target);
    return target;
  }

  /// 清洗手打的路径：去空白，去掉「复制为路径」带出来的成对引号。
  String _normalizePath(String rawPath) {
    var target = rawPath.trim();
    if (target.length >= 2) {
      final first = target[0];
      final last = target[target.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        target = target.substring(1, target.length - 1).trim();
      }
    }
    return target;
  }

  /// 选择器与手填共用的落地流程：授权 → 建目录试写 → 留持久授权 → 存设置。
  Future<void> _applyDirectory(String target) async {
    await _ensureStorageAccess();
    try {
      await ensureDirectoryWritable(target);
    } catch (e) {
      KazumiLogger().w('LocalBackup: directory not writable: $target', error: e);
      throw const LocalBackupException('这个目录无法写入，请检查路径是否正确、是否有访问权限');
    }
    await _persistAccess(target);
    await GStorage.putSetting(SettingsKeys.localBackupDirectory, target);
    _accessLost = false;
  }

  Future<void> resetDirectory() async {
    await GStorage.putSetting(SettingsKeys.localBackupDirectoryBookmark, '');
    await GStorage.putSetting(SettingsKeys.localBackupDirectory, '');
    _accessLost = false;
  }

  /// 读写前恢复 macOS 的目录授权；其它平台在选择时就拿到了权限。
  Future<void> restoreAccess() async {
    final target = directory;
    if (!Platform.isMacOS || target.isEmpty) return;
    try {
      final restored = await _bookmarks.resolveBookmark(
        GStorage.getSetting(SettingsKeys.localBackupDirectoryBookmark),
        isDirectory: true,
      );
      _accessLost =
          !await _bookmarks.startAccessingSecurityScopedResource(restored);
      if (!_accessLost && !path.equals(restored.path, target)) {
        await GStorage.putSetting(
          SettingsKeys.localBackupDirectory,
          restored.path,
        );
      }
    } catch (e) {
      _accessLost = true;
      KazumiLogger().e(
        'LocalBackup: failed to restore access to $target',
        error: e,
      );
    }
  }

  Future<void> _persistAccess(String target) async {
    if (!Platform.isMacOS) return;
    final String bookmark;
    try {
      bookmark = await _bookmarks.bookmark(Directory(target));
    } catch (e) {
      KazumiLogger().e('LocalBackup: failed to bookmark $target', error: e);
      throw const LocalBackupException('无法获得该目录的持久访问权限，请更换目录');
    }
    await GStorage.putSetting(
      SettingsKeys.localBackupDirectoryBookmark,
      bookmark,
    );
  }

  Future<String?> _pickDirectory(String? initialDirectory) async {
    if (!Platform.isAndroid) {
      return FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择本地备份目录',
        initialDirectory: initialDirectory,
      );
    }
    try {
      await _ensureStorageAccess();
      return await _androidChannel.invokeMethod<String>('pickDirectory', {
        'initialDirectory': initialDirectory,
      });
    } on PlatformException catch (e) {
      throw LocalBackupException(
        e.code == 'UNSUPPORTED_DIRECTORY'
            ? '请选择内部存储或 SD 卡中的本地文件夹'
            : '选择备份目录失败，请重试',
      );
    }
  }

  /// Android 上要直接拿文件路径，必须先要到全盘访问权限；其它平台不用管。
  ///
  /// 选择器和手填都要过这一关，所以单独拆出来 —— 手填时用户可能还没授权，
  /// 没有权限的话 `ensureDirectoryWritable` 会直接失败，报错信息又看不懂。
  Future<void> _ensureStorageAccess() async {
    if (!Platform.isAndroid) return;
    final granted =
        await _androidChannel.invokeMethod<bool>('requestStorageAccess') ??
        false;
    if (!granted) {
      throw const LocalBackupException('未授予存储访问权限，备份目录未修改');
    }
  }

  String _requireDirectory() {
    final target = directory;
    if (target.isEmpty) {
      throw const LocalBackupException('请先选择本地备份目录');
    }
    if (_accessLost) {
      throw const LocalBackupException('备份目录访问权限已失效，请重新选择该目录');
    }
    return target;
  }

  /// 按开关把选中的内容写进备份目录，返回实际备份的条目名（顿号分隔）。
  Future<String> backup() async {
    await restoreAccess();
    _requireDirectory();
    if (!hasSelection) {
      // 跟随云端时四项都不在本地，用户看到「请先选择要备份的内容」会找不着地方改。
      throw LocalBackupException(
        followWebDav
            ? 'WebDAV 尚未启用任何同步内容，请先在【启用 WebDAV】里选择'
            : '请先选择要备份的内容',
      );
    }
    final done = await _writeBackup();
    KazumiLogger().i('LocalBackup: backed up. items=$done');
    return done.join('、');
  }

  /// 真正的写盘动作，手动与自动备份共用。
  ///
  /// 前置条件（目录、内容选择、凭据是否存在）由调用方负责校验，
  /// 这里只管把选中的东西写出去，返回写成功的条目名。
  ///
  /// [skipEmptyBoxes] 供自动备份使用：本地某个箱为空、而目录里已有对应的
  /// 旧备份时跳过，不要用一份空数据把用户之前的好备份冲掉。手动备份保持
  /// 忠实快照语义，不跳过任何项。
  ///
  /// [only] 限定只写哪几个分区，null 表示按开关全写。手动备份永远传 null，
  /// 用户点「立即备份」要的就是一份完整快照。
  Future<List<String>> _writeBackup({
    bool skipEmptyBoxes = false,
    Set<LocalBackupSection>? only,
  }) async {
    final target = _requireDirectory();
    final items = [
      for (final item in localBackupItems)
        if (isSelected(item) &&
            (only == null || only.contains(item.section)) &&
            (!skipEmptyBoxes || item.autoBackup))
          item,
    ];
    // 先校验凭据，避免其它几项写完才在最后一步失败。
    if (items.any((item) => item.section == LocalBackupSection.credentials) &&
        !WebDav().hasAnyCredential) {
      throw const LocalBackupException('本地还没有可备份的账号信息');
    }
    await Directory(target).create(recursive: true);
    final done = <String>[];

    for (final item in items) {
      final wrote = await _writeItem(
        item,
        target,
        skipEmptyBoxes: skipEmptyBoxes,
      );
      if (wrote) done.add(item.title);
    }
    return done;
  }

  /// 写单项内容，返回是否真的写了（空箱跳过时为 false）。
  Future<bool> _writeItem(
    LocalBackupItem item,
    String target, {
    required bool skipEmptyBoxes,
  }) async {
    switch (item.section) {
      case LocalBackupSection.history:
        await GStorage.histories.flush();
        final historyPath = path.join(target, item.fileNames.first);
        if (skipEmptyBoxes &&
            GStorage.histories.isEmpty &&
            await File(historyPath).exists()) {
          KazumiLogger().i('LocalBackup: skip empty histories backup');
          return false;
        }
        await GStorage.backupBox('histories', historyPath);
        return true;

      case LocalBackupSection.collect:
        await GStorage.collectibles.flush();
        await GStorage.collectChanges.flush();
        final collectiblesPath = path.join(target, item.fileNames.first);
        if (skipEmptyBoxes &&
            GStorage.collectibles.isEmpty &&
            await File(collectiblesPath).exists()) {
          KazumiLogger().i('LocalBackup: skip empty collectibles backup');
          return false;
        }
        await GStorage.backupBox('collectibles', collectiblesPath);
        await GStorage.backupBox(
          'collectchanges',
          path.join(target, item.fileNames.last),
        );
        return true;

      case LocalBackupSection.shield:
        final payload = <String, Object?>{
          'version': 1,
          'backupAt': DateTime.now().toIso8601String(),
          'rules': _shieldRepository.getRules(),
        };
        await File(
          path.join(target, item.fileNames.first),
        ).writeAsString(jsonEncode(payload), flush: true);
        return true;

      case LocalBackupSection.credentials:
        await _writeCredentials(path.join(target, item.fileNames.first));
        return true;

      case LocalBackupSection.settings:
        await GStorage.exportSettingsBox(path.join(target, item.fileNames.first));
        return true;
    }
  }

  /// 从备份目录把选中的内容合并回本地，返回实际恢复的条目名与缺失项。
  ///
  /// 某个条目在目录里没有对应文件时跳过并记下来；全都没有就报错。
  ///
  /// [sourceDirectory] 一次性恢复目录，不改写「本地备份路径」。
  /// [ignoreSelection] 总开关关着时子开关是隐藏的，只能按全量恢复。
  Future<LocalBackupRestoreResult> restore({
    String? sourceDirectory,
    bool ignoreSelection = false,
  }) async {
    final String target;
    final once = sourceDirectory?.trim() ?? '';
    if (once.isNotEmpty) {
      target = once;
    } else {
      await restoreAccess();
      target = _requireDirectory();
    }
    if (!ignoreSelection && !hasSelection) {
      throw const LocalBackupException('请先选择要恢复的内容');
    }
    final items = [
      for (final item in localBackupItems)
        if (ignoreSelection || isSelected(item)) item,
    ];
    final done = <String>[];
    final missing = <String>[];
    var requiresRestart = false;

    for (final item in items) {
      final restored = await _restoreItem(item, target);
      if (restored) {
        done.add(item.title);
        if (item.restoreNeedsRestart) requiresRestart = true;
      } else {
        missing.add(item.title);
      }
    }

    if (done.isEmpty) {
      throw LocalBackupException('本地目录里没有${missing.join('、')}的备份文件，请先备份一次');
    }
    KazumiLogger().i(
      'LocalBackup: restored from $target. items=$done missing=$missing',
    );
    return LocalBackupRestoreResult(
      done: done,
      missing: missing,
      requiresRestart: requiresRestart,
    );
  }

  /// 恢复单项内容，返回该目录里是否有对应备份并已恢复。
  Future<bool> _restoreItem(LocalBackupItem item, String target) async {
    switch (item.section) {
      case LocalBackupSection.history:
        final file = path.join(target, item.fileNames.first);
        if (!await File(file).exists()) return false;
        await GStorage.patchHistory(file);
        return true;

      case LocalBackupSection.collect:
        final collectiblesFile = path.join(target, item.fileNames.first);
        if (!await File(collectiblesFile).exists()) return false;
        final changesFile = path.join(target, item.fileNames.last);
        final remoteCollectibles = await GStorage.getCollectiblesFromFile(
          collectiblesFile,
        );
        final remoteChanges = await File(changesFile).exists()
            ? await GStorage.getCollectChangesFromFile(changesFile)
            : <CollectedBangumiChange>[];
        await GStorage.patchCollectibles(remoteCollectibles, remoteChanges);
        return true;

      case LocalBackupSection.shield:
        final file = path.join(target, item.fileNames.first);
        if (!await File(file).exists()) return false;
        await _restoreShieldRules(file);
        return true;

      case LocalBackupSection.credentials:
        final file = path.join(target, item.fileNames.first);
        if (!await File(file).exists()) return false;
        await _restoreCredentials(file);
        return true;

      case LocalBackupSection.settings:
        final file = path.join(target, item.fileNames.first);
        if (!await File(file).exists()) return false;
        await GStorage.restoreSettingsBox(file);
        return true;
    }
  }

  Future<void> _writeCredentials(String filePath) async {
    final credentials = <String, String>{
      for (final key in WebDav.credentialKeys)
        if (GStorage.getSetting(key).trim().isNotEmpty)
          key.name: GStorage.getSetting(key),
    };
    if (credentials.isEmpty) {
      throw const LocalBackupException('本地还没有可备份的账号信息');
    }
    final payload = <String, Object?>{
      'version': 1,
      'backupAt': DateTime.now().toIso8601String(),
      'credentials': credentials,
    };
    // 与云端那份同格式：`{version, cipher, data}`，data 是 AES 密文。
    // 本地文件也加密，是为了备份目录可能被同步盘/别人翻到。
    final envelope = <String, Object?>{
      'version': 2,
      'cipher': 'aes-256-gcm',
      'data': CredentialCipher.encryptToBase64(jsonEncode(payload)),
    };
    await File(filePath).writeAsString(jsonEncode(envelope), flush: true);
  }

  Future<void> _restoreCredentials(String filePath) async {
    final decoded = jsonDecode(await File(filePath).readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const LocalBackupException('账号信息备份文件格式不正确');
    }
    final cipher = decoded['cipher'];
    final data = decoded['data'];
    if (cipher is! String || cipher.isEmpty || data is! String) {
      throw const LocalBackupException('账号信息备份文件格式不正确');
    }
    final inner = jsonDecode(CredentialCipher.decryptFromBase64(data));
    if (inner is! Map<String, dynamic>) {
      throw const LocalBackupException('账号信息备份文件格式不正确');
    }
    final credentials = inner['credentials'];
    if (credentials is! Map<String, dynamic>) {
      throw const LocalBackupException('账号信息备份文件格式不正确');
    }
    final byName = {for (final key in WebDav.credentialKeys) key.name: key};
    var restored = 0;
    for (final entry in credentials.entries) {
      final key = byName[entry.key];
      final value = entry.value;
      if (key == null || value is! String) continue;
      await GStorage.putSetting(key, value);
      restored++;
    }
    KazumiLogger().i('LocalBackup: credentials restored. keys=$restored');
  }

  Future<void> _restoreShieldRules(String filePath) async {
    final decoded = jsonDecode(await File(filePath).readAsString());
    if (decoded is! Map<String, dynamic> || decoded['rules'] is! List) {
      throw const LocalBackupException('弹幕屏蔽词备份文件格式不正确');
    }
    var restored = 0;
    for (final rule in decoded['rules'] as List) {
      // 旧版本写下的非法规则直接跳过，不让一条坏数据中断整次恢复。
      if (rule is! String || DanmakuShieldRule.validate(rule) != null) continue;
      await _shieldRepository.setRule(rule, deleted: false);
      restored++;
    }
    KazumiLogger().i('LocalBackup: shield rules restored. count=$restored');
  }
}
