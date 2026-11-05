import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:path_provider/path_provider.dart';

/// Bangumi 条目 ID → AniList 番剧 ID 的离线映射。
///
/// 数据从 BangumiExtLinker 的 anime_map.csv 在线获取，精简成两列后
/// 缓存到应用私有目录，每天 0 点后的首次启动刷新一次（app 不在后台
/// 定时唤醒，当日内重启只加载缓存）；获取失败沿用本地缓存。
class BgmAniListMap {
  BgmAniListMap._();

  static const String _csvUrl =
      'https://rhilip.github.io/BangumiExtLinker/data/anime_map.csv';

  static Map<String, int>? _cache;
  static Future<Map<String, int>>? _loading;
  static DateTime? _lastFetch;
  static String? _etag;

  /// 加载映射表：先读本地缓存，跨天后首次启动时刷新，全部失败则无映射。
  static Future<Map<String, int>> ensureLoaded() {
    final cached = _cache;
    if (cached != null) return Future.value(cached);
    return _loading ??= _load();
  }

  /// 上次拉取是否在 0 点之前（即今天还没刷新过）。
  ///
  /// 进程内只判一次：_cache 非空后 ensureLoaded 直接返回，跨午夜不重查。
  /// 缓存不存在或无法解析时视为需要刷新。
  static bool _stale() {
    final last = _lastFetch;
    if (last == null) return true;
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    return last.isBefore(todayStart);
  }

  /// 上游 CSV 的 ETag（内容哈希的弱化形式），内容不变时可用 304 免下载。
  ///
  /// 随精简缓存一起持久化（首行 ETag\换行\JSON），读到即恢复。
  static String? get etag => _etag;

  static Future<Map<String, int>> _load() async {
    final cacheFile = await _cacheFile();
    try {
      if (await cacheFile.exists()) {
        final raw = await cacheFile.readAsString();
        final sep = raw.indexOf('\n');
        if (sep > 0) {
          _etag = raw.substring(0, sep);
          _cache = _parse(raw.substring(sep + 1));
        } else {
          _cache = _parse(raw);
        }
        _lastFetch = (await cacheFile.stat()).modified;
      }
    } catch (error, stackTrace) {
      KazumiLogger().w('BgmAniListMap: read cache failed',
          error: error, stackTrace: stackTrace);
    }

    // 每天 0 点后首次启动刷新一次；内容没变时走 304 免下载，失败沿用本地缓存。
    if (_stale() || _cache == null || _cache!.isEmpty) {
      try {
        final response = await _fetchCsv();
        if (response.statusCode == 304) {
          // 内容没变，只更新拉取时间，缓存文件不用重写。
          _lastFetch = DateTime.now();
          KazumiLogger().i('BgmAniListMap: not modified (etag match)');
        } else {
          final raw = response.data is String
              ? response.data as String
              : (response.data ?? '').toString();
          final slim = await compute(_slimCsv, raw);
          final newEtag = response.headers.value(HttpHeaders.etagHeader);
          await cacheFile.writeAsString(
              '${newEtag ?? ''}\n$slim');
          _cache = _parse(slim);
          _etag = newEtag;
          _lastFetch = DateTime.now();
          KazumiLogger()
              .i('BgmAniListMap: refreshed, ${_cache!.length} entries');
        }
      } catch (error, stackTrace) {
        KazumiLogger().w('BgmAniListMap: fetch failed, keep stale cache',
            error: error, stackTrace: stackTrace);
      }
    }
    _loading = null;
    return _cache ?? const {};
  }

  /// 带 If-None-Match 条件请求 CSV；服务器内容未变时返回 304 空体。
  ///
  /// 默认 validateStatus 视 304 为失败，这里放行让调用方按状态码分流。
  static Future<Response<String>> _fetchCsv() async {
    return DioFactory.pluginDio.get<String>(
      _csvUrl,
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 60),
        validateStatus: (status) => status != null && status < 400,
        headers: {
          if (_etag != null && _etag!.isNotEmpty)
            HttpHeaders.ifNoneMatchHeader: _etag!,
        },
      ),
    );
  }

  static Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/anime_schedule/bgm_anilist_map.json');
  }

  /// 解析精简后的 JSON 缓存。
  static Map<String, int> _parse(String raw) {
    final decoded = jsonDecode(raw);
    final result = <String, int>{};
    if (decoded is Map) {
      decoded.forEach((key, value) {
        if (value is int) result['$key'] = value;
      });
    }
    return result;
  }

  /// 从 CSV 原文提取 bgm_id → anilist_id 两列。在 isolate 中执行。
  ///
  /// name/name_cn 列含逗号且带引号包裹，用状态机逐字符解析。
  static String _slimCsv(String csv) {
    final result = <String, int>{};
    final rows = _splitCsvRows(csv);
    if (rows.isEmpty) return jsonEncode(result);
    final head = rows.first;
    final bgmCol = head.indexOf('bgm_id');
    final anilistCol = head.indexOf('anilist_id');
    if (bgmCol < 0 || anilistCol < 0) return jsonEncode(result);

    for (var i = 1; i < rows.length; i++) {
      final cols = rows[i];
      if (anilistCol >= cols.length || bgmCol >= cols.length) continue;
      final bgm = cols[bgmCol];
      final id = int.tryParse(cols[anilistCol]);
      if (bgm.isEmpty || id == null) continue;
      result[bgm] = id;
    }
    return jsonEncode(result);
  }

  /// 按RFC 4180 拆 CSV 行：引号内的逗号不算分隔符，"" 转义为 "。
  static List<List<String>> _splitCsvRows(String csv) {
    final rows = <List<String>>[];
    final field = StringBuffer();
    final row = <String>[];
    var inQuotes = false;
    for (var i = 0; i < csv.length; i++) {
      final c = csv[i];
      if (inQuotes) {
        if (c == '"') {
          if (i + 1 < csv.length && csv[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(c);
        }
      } else if (c == '"') {
        inQuotes = true;
      } else if (c == ',') {
        row.add(field.toString());
        field.clear();
      } else if (c == '\r') {
        // 跳过，行结束由 \n 处理
      } else if (c == '\n') {
        row.add(field.toString());
        rows.add(row);
        field.clear();
        row.clear();
      } else {
        field.write(c);
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field.toString());
      rows.add(row);
    }
    return rows;
  }

  /// 查 bgmId 对应的 AniList ID，无映射或未加载返回 null。
  static int? lookup(int bgmId) => _cache?['$bgmId'];
}
