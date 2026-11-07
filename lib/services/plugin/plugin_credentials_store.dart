import 'dart:convert';

import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/logging/logger.dart';

/// 声明了登录流程的规则（规则 JSON 里的 `auth`）所用的本地凭据与令牌缓存。
///
/// 凭据由用户在「规则账号」设置页里输入，之后
/// 绝不离开这台设备——不能出现在规则文件、日志或任何导出内容里。
/// 除了规则自己的登录接口，不会发出任何其它网络请求。
class PluginCredentialsStore {
  PluginCredentialsStore._();

  /// 一个内存状态为空的干净实例，供测试使用。
  factory PluginCredentialsStore.fresh() => PluginCredentialsStore._();

  static PluginCredentialsStore instance = PluginCredentialsStore._();

  static const String _boxName = 'pluginCredentials';

  Box<String>? _box;
  final Map<String, _Entry> _cache = {};

  Future<Box<String>> _getBox() async {
    final box = _box;
    if (box != null && box.isOpen) return box;
    return _box = await Hive.openBox<String>(_boxName);
  }

  String _key(String pluginName) => pluginName.toLowerCase().trim();

  _Entry? _entryFor(String pluginName) {
    return _cache[_key(pluginName)];
  }

  Future<void> _putEntry(String pluginName, _Entry entry) async {
    _cache[_key(pluginName)] = entry;
    try {
      final box = await _getBox();
      await box.put(_key(pluginName), jsonEncode(entry.toJson()));
    } catch (error) {
      KazumiLogger().w(
          'PluginCredentialsStore: failed to persist entry', error: error);
    }
  }

  /// 从磁盘恢复缓存条目。要在 GStorage.init() 之后调用一次；
  /// 失败时存储保持为空（用户重新输一遍凭据）。
  Future<void> load() async {
    try {
      final box = await _getBox();
      _cache.clear();
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw is! String || raw.isEmpty) continue;
        try {
          final entry = _Entry.fromJson(jsonDecode(raw) as Map<String, dynamic>);
          _cache['$key'] = entry;
        } catch (_) {
          // 跳过格式损坏的条目，而不是让整个存储失效。
        }
      }
    } catch (error) {
      KazumiLogger().w(
          'PluginCredentialsStore: failed to load entries', error: error);
    }
  }

  /// [pluginName] 之前保存的用户名，没有则为 null。
  String? usernameFor(String pluginName) =>
      _entryFor(pluginName)?.username;

  /// [pluginName] 之前保存的密码，没有则为 null。
  String? passwordFor(String pluginName) =>
      _entryFor(pluginName)?.password;

  /// 用户是否已经为 [pluginName] 填过凭据。
  bool hasCredentials(String pluginName) {
    final entry = _entryFor(pluginName);
    return entry != null &&
        entry.username.trim().isNotEmpty &&
        entry.password.isNotEmpty;
  }

  /// 保存或替换 [pluginName] 的凭据。已缓存的令牌保持不变：
  /// 保存一份完全相同的凭据不该强制重新登录。
  Future<void> saveCredentials(
    String pluginName, {
    required String username,
    required String password,
  }) async {
    final existing = _entryFor(pluginName);
    final entry = (existing ?? _Entry()).copyWith(
      username: username.trim(),
      password: password,
    );
    await _putEntry(pluginName, entry);
  }

  /// 只替换用户名，保留已存的密码。
  ///
  /// 没有可保留的密码时返回 false，此时调用方必须向用户索要密码。
  Future<bool> saveUsername(String pluginName, String username) async {
    final existing = _entryFor(pluginName);
    if (existing == null || existing.password.isEmpty) return false;
    await _putEntry(pluginName, existing.copyWith(username: username.trim()));
    return true;
  }

  /// [pluginName] 缓存的令牌，没有则为 null。
  String? tokenFor(String pluginName) => _entryFor(pluginName)?.token;

  /// 缓存 [pluginName] 的登录令牌。
  Future<void> saveToken(String pluginName, String token) async {
    final existing = _entryFor(pluginName) ?? _Entry();
    await _putEntry(
        pluginName, existing.copyWith(token: token));
  }

  /// 丢掉缓存的令牌（不动凭据），让下一次请求触发重新登录。
  /// 服务端拒绝令牌时用。
  Future<void> clearToken(String pluginName) async {
    final existing = _entryFor(pluginName);
    if (existing == null || existing.token == null) return;
    await _putEntry(pluginName, existing.copyWith(token: null));
  }

  /// 清掉 [pluginName] 名下存储的全部内容。
  Future<void> clearAll(String pluginName) async {
    _cache.remove(_key(pluginName));
    try {
      final box = await _getBox();
      await box.delete(_key(pluginName));
    } catch (error) {
      KazumiLogger().w(
          'PluginCredentialsStore: failed to remove entry', error: error);
    }
  }
}

class _Entry {
  _Entry({this.username = '', this.password = '', this.token});

  factory _Entry.fromJson(Map<String, dynamic> json) => _Entry(
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
        token: json['token'] as String?,
      );

  String username;
  String password;
  String? token;

  bool get _hasToken => token != null && token!.isNotEmpty;

  _Entry copyWith({String? username, String? password, String? token}) {
    return _Entry(
      username: username ?? this.username,
      password: password ?? this.password,
      // 显式传 null 表示清空令牌。
      token: token == null && this.token != null ? null : (token ?? this.token),
    );
  }

  Map<String, dynamic> toJson() => {
        'username': username,
        'password': password,
        if (_hasToken) 'token': token,
      };
}
