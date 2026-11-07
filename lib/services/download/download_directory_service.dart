import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/file_system.dart';
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';
import 'package:path/path.dart' as path;

class DownloadDirectoryException implements Exception {
  const DownloadDirectoryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 负责下载存放位置。访问权在选定目录时就确定了，
/// 在 macOS 上还会每次启动恢复一次，因此下载、播放与删除
/// 都能直接用普通的文件系统路径工作。
class DownloadDirectoryService {
  static final DownloadDirectoryService _instance =
      DownloadDirectoryService._internal();
  factory DownloadDirectoryService() => _instance;
  DownloadDirectoryService._internal();

  static const _androidChannel = MethodChannel(
    'com.predidit.kazumi/download_directory',
  );
  final _bookmarks = SecureBookmarks();
  bool _accessLost = false;

  bool get supportsCustomDirectory =>
      Platform.isAndroid || Platform.isMacOS || Platform.isWindows;

  /// 使用默认目录时为空。
  String get customDirectory => supportsCustomDirectory
      ? GStorage.getSetting(SettingsKeys.downloadDirectory).trim()
      : '';

  /// 在任何读写下载内容之前，先恢复沙盒对自定义目录的访问权。
  /// 其它平台在选定目录时获得的访问权会一直有效。
  Future<void> restoreAccess() async {
    final directory = customDirectory;
    if (!Platform.isMacOS || directory.isEmpty) return;
    try {
      final restored = await _bookmarks.resolveBookmark(
        GStorage.getSetting(SettingsKeys.downloadDirectoryBookmark),
        isDirectory: true,
      );
      _accessLost =
          !await _bookmarks.startAccessingSecurityScopedResource(restored);
      // 用户搬动目录时，书签会跟着走。
      if (!_accessLost && !path.equals(restored.path, directory)) {
        await GStorage.putSetting(
          SettingsKeys.downloadDirectory,
          restored.path,
        );
      }
    } catch (e) {
      _accessLost = true;
      KazumiLogger().e(
        'DownloadDirectoryService: failed to restore access to $directory',
        error: e,
      );
    }
  }

  /// 新下载的根目录。自定义目录若访问权恢复失败，
  /// 就直接报错，而不是悄悄把下载改到别处。
  Future<String> getDownloadDirectory() async {
    final directory = customDirectory;
    if (directory.isEmpty) return getDefaultDownloadDirectory();
    if (_accessLost) {
      throw const DownloadDirectoryException('下载目录访问权限已失效，请在下载设置中重新选择该目录');
    }
    return directory;
  }

  /// 用户取消时返回 null。目录要等验证过可写、且访问权已持久化之后
  /// 才会被保存下来。
  Future<String?> selectDirectory() async {
    if (!supportsCustomDirectory) {
      throw const DownloadDirectoryException('当前平台不支持手动选择目录');
    }
    final current = customDirectory.isEmpty
        ? await getDefaultDownloadDirectory()
        : customDirectory;
    final selected = await _pickDirectory(
      await Directory(current).exists() ? current : null,
    );
    if (selected == null || selected.isEmpty) return null;
    await ensureDirectoryWritable(selected);
    await _persistAccess(selected);
    await GStorage.putSetting(SettingsKeys.downloadDirectory, selected);
    // 选择器给出的授权覆盖本次会话剩余时间。
    _accessLost = false;
    return selected;
  }

  Future<void> resetDirectory() async {
    await GStorage.putSetting(SettingsKeys.downloadDirectoryBookmark, '');
    await GStorage.putSetting(SettingsKeys.downloadDirectory, '');
    _accessLost = false;
  }

  Future<String?> _pickDirectory(String? initialDirectory) async {
    if (!Platform.isAndroid) {
      return FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择下载位置',
        initialDirectory: initialDirectory,
      );
    }
    try {
      // 只拿到文档树授权，还不足以使用直接文件路径。
      final granted =
          await _androidChannel.invokeMethod<bool>('requestStorageAccess') ??
          false;
      if (!granted) {
        throw const DownloadDirectoryException('未授予存储访问权限，下载位置未修改');
      }
      return await _androidChannel.invokeMethod<String>('pickDirectory', {
        'initialDirectory': initialDirectory,
      });
    } on PlatformException catch (e) {
      throw DownloadDirectoryException(
        e.code == 'UNSUPPORTED_DIRECTORY'
            ? '请选择内部存储或 SD 卡中的本地文件夹'
            : '选择下载位置失败，请重试',
      );
    }
  }

  Future<void> _persistAccess(String directory) async {
    if (!Platform.isMacOS) return;
    final String bookmark;
    try {
      bookmark = await _bookmarks.bookmark(Directory(directory));
    } catch (e) {
      KazumiLogger().e(
        'DownloadDirectoryService: failed to bookmark $directory',
        error: e,
      );
      throw const DownloadDirectoryException('无法获得该目录的持久访问权限，请更换目录');
    }
    await GStorage.putSetting(SettingsKeys.downloadDirectoryBookmark, bookmark);
  }
}
