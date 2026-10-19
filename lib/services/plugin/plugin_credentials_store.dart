import 'dart:convert';

import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/logging/logger.dart';

/// Locally stored credentials and cached tokens for rules that declare a
/// login flow (`auth` in the rule JSON).
///
/// Credentials are entered by the user in the "规则账号" settings page and
/// never leave this device — they must not end up in rule files, logs or
/// any network request other than the rule's own login endpoint.
class PluginCredentialsStore {
  PluginCredentialsStore._();

  /// A fresh store with empty in-memory state; used by tests.
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

  /// Restores cached entries from disk. Call once after GStorage.init();
  /// failures leave the store empty (user re-enters credentials).
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
          // Skip malformed entries instead of failing the whole store.
        }
      }
    } catch (error) {
      KazumiLogger().w(
          'PluginCredentialsStore: failed to load entries', error: error);
    }
  }

  /// Username previously saved for [pluginName], or null.
  String? usernameFor(String pluginName) =>
      _entryFor(pluginName)?.username;

  /// Password previously saved for [pluginName], or null.
  String? passwordFor(String pluginName) =>
      _entryFor(pluginName)?.password;

  /// Whether the user has entered credentials for [pluginName].
  bool hasCredentials(String pluginName) {
    final entry = _entryFor(pluginName);
    return entry != null &&
        entry.username.trim().isNotEmpty &&
        entry.password.isNotEmpty;
  }

  /// Saves or replaces the credentials for [pluginName]. The cached token is
  /// kept: saving identical credentials should not force a re-login.
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

  /// Replaces only the username, keeping the stored password.
  ///
  /// Returns false when there is no password to keep, in which case the
  /// caller must ask the user for one.
  Future<bool> saveUsername(String pluginName, String username) async {
    final existing = _entryFor(pluginName);
    if (existing == null || existing.password.isEmpty) return false;
    await _putEntry(pluginName, existing.copyWith(username: username.trim()));
    return true;
  }

  /// Cached token for [pluginName], or null.
  String? tokenFor(String pluginName) => _entryFor(pluginName)?.token;

  /// Caches the login token for [pluginName].
  Future<void> saveToken(String pluginName, String token) async {
    final existing = _entryFor(pluginName) ?? _Entry();
    await _putEntry(
        pluginName, existing.copyWith(token: token));
  }

  /// Drops the cached token (not the credentials) so the next request
  /// triggers a fresh login. Used when the server rejects the token.
  Future<void> clearToken(String pluginName) async {
    final existing = _entryFor(pluginName);
    if (existing == null || existing.token == null) return;
    await _putEntry(pluginName, existing.copyWith(token: null));
  }

  /// Removes everything stored for [pluginName].
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
      // Explicit null clears the token.
      token: token == null && this.token != null ? null : (token ?? this.token),
    );
  }

  Map<String, dynamic> toJson() => {
        'username': username,
        'password': password,
        if (_hasToken) 'token': token,
      };
}
