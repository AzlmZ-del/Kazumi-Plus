import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:kazumi/services/logging/logger.dart';

/// Bangumi 条目 ID → AniList 番剧 ID 的离线映射。
///
/// 数据来自 BangumiExtLinker 的 anime_map.json，只保留两列（13634 条，约 195 KB）。
class BgmAniListMap {
  BgmAniListMap._();

  static const String _assetPath = 'assets/anime_schedule/bgm_anilist_map.json';

  static Map<String, int>? _cache;
  static Future<Map<String, int>>? _loading;

  /// 同步读取已加载的映射表，未加载时为 null。
  static Map<String, int>? get loaded => _cache;

  /// 加载映射表，重复调用只读一次资源。
  static Future<Map<String, int>> ensureLoaded() {
    final cached = _cache;
    if (cached != null) return Future.value(cached);
    return _loading ??= _load();
  }

  static Future<Map<String, int>> _load() async {
    try {
      final raw = await rootBundle.loadString(_assetPath);
      final decoded = jsonDecode(raw);
      final result = <String, int>{};
      if (decoded is Map) {
        decoded.forEach((key, value) {
          if (value is int) {
            result['$key'] = value;
          }
        });
      }
      return _cache = result;
    } catch (error, stackTrace) {
      KazumiLogger().e('BgmAniListMap: failed to load asset',
          error: error, stackTrace: stackTrace);
      // 失败也写空表，避免重复读资源。
      return _cache = const {};
    } finally {
      _loading = null;
    }
  }

  /// 查 bgmId 对应的 AniList ID，无映射返回 null。
  static int? lookup(int bgmId) => _cache?['$bgmId'];
}
