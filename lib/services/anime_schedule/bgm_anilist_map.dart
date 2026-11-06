import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:dio/dio.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/rules_mirror.dart';
import 'package:path_provider/path_provider.dart';

/// Bangumi 条目 ID → AniList 番剧 ID 的离线映射。
///
/// 取自 BangumiExtLinker 的 anime_map.csv，精简成两列后缓存到应用私有目录。
class BgmAniListMap {
  BgmAniListMap._();

  /// 直连档用它：无代理环境实测比 raw.githubusercontent.com 更通。
  static const String _csvUrlPages =
      'https://rhilip.github.io/BangumiExtLinker/data/anime_map.csv';

  /// 镜像档用它：前缀式镜像只认 GitHub 域名，拼 github.io 会 404。
  static const String _csvUrlRaw =
      'https://raw.githubusercontent.com/rhilip/BangumiExtLinker/'
      'master/data/anime_map.csv';

  /// gitcode 只镜像 KazumiRules，套不到 CSV，退回 Pages。
  static String get _csvUrl => switch (RulesMirror.current) {
        RulesMirror.ghProxy => '${ApiEndpoints.ghProxyMirror}$_csvUrlRaw',
        RulesMirror.ghfast => '${ApiEndpoints.ghfastMirror}$_csvUrlRaw',
        RulesMirror.gitcode || RulesMirror.direct => _csvUrlPages,
      };

  static Map<String, int>? _cache;
  static Future<Map<String, int>>? _loading;
  static DateTime? _lastFetch;
  static String? _etag;

  /// 上次拉取用的档位，切档后要重拉。
  static String? _lastFetchedSource;

  static bool _refreshInFlight = false;

  /// 只读本地缓存，不联网；刷新由 [refreshInBackground] 负责。
  static Future<Map<String, int>> ensureLoaded() {
    final cached = _cache;
    if (cached != null) return Future.value(cached);
    return _loading ??= _load();
  }

  /// 上次拉取是否在 0 点之前（今天还没刷过）。
  static bool _stale() {
    final last = _lastFetch;
    if (last == null) return true;
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    return last.isBefore(todayStart);
  }

  /// 随精简缓存持久化（首行 ETag + 换行 + JSON）。
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
        _lastFetchedSource = await _readSourceMarker(cacheFile);
      }
    } catch (error, stackTrace) {
      KazumiLogger().w('BgmAniListMap: read cache failed',
          error: error, stackTrace: stackTrace);
    }
    _loading = null;
    return _cache ?? const {};
  }

  /// 后台静默刷新：0 点后首次启动或切换了加速档位时触发。
  ///
  /// 成功覆盖缓存，失败静默忽略。调用方用 unawaited，不要 await。
  static Future<void> refreshInBackground() async {
    if (_refreshInFlight) return;
    final sourceChanged = _lastFetchedSource != null &&
        _lastFetchedSource != RulesMirror.current.name;
    if (!_stale() && !sourceChanged) return;
    _refreshInFlight = true;
    try {
      var response = await _fetchCsv();
      // 304 配空缓存会永久锁死，丢弃 ETag 强制重拉。
      if (response.statusCode == 304 &&
          (_cache == null || _cache!.isEmpty)) {
        KazumiLogger().w(
            'BgmAniListMap: 304 but cache is empty, refetching without etag');
        _etag = null;
        response = await _fetchCsv();
      }
      if (response.statusCode == 304) {
        _lastFetch = DateTime.now();
        _lastFetchedSource = RulesMirror.current.name;
        await _writeSourceMarker(await _cacheFile());
        KazumiLogger().i('BgmAniListMap: not modified (etag match)');
        return;
      }
      final raw = response.data is String
          ? response.data as String
          : (response.data ?? '').toString();
      final slim = await compute(_slimCsv, raw);
      final newEtag = response.headers.value(HttpHeaders.etagHeader);
      final cacheFile = await _cacheFile();
      // 原子写，避免进程被杀时留下半截 JSON。
      final temp = File('${cacheFile.path}.tmp');
      await temp.writeAsString('${newEtag ?? ''}\n$slim', flush: true);
      await temp.rename(cacheFile.path);
      _cache = _parse(slim);
      _etag = newEtag;
      _lastFetch = DateTime.now();
      _lastFetchedSource = RulesMirror.current.name;
      await _writeSourceMarker(cacheFile);
      KazumiLogger()
          .i('BgmAniListMap: background refresh ok, ${_cache!.length} entries');
    } catch (error, stackTrace) {
      KazumiLogger().w('BgmAniListMap: background refresh failed, ignored',
          error: error, stackTrace: stackTrace);
    } finally {
      _refreshInFlight = false;
    }
  }

  static Future<String?> _readSourceMarker(File cacheFile) async {
    try {
      final marker = File('${cacheFile.path}.source');
      if (!await marker.exists()) return null;
      final text = (await marker.readAsString()).trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeSourceMarker(File cacheFile) async {
    try {
      await File('${cacheFile.path}.source')
          .writeAsString(RulesMirror.current.name, flush: true);
    } catch (_) {}
  }

  /// 带 If-None-Match 条件请求；内容未变时返回 304 空体。
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
    // writeAsString 不建父目录，首次落盘会 PathNotFoundException。
    final target = Directory('${dir.path}/anime_schedule');
    if (!target.existsSync()) {
      await target.create(recursive: true);
    }
    return File('${target.path}/bgm_anilist_map.json');
  }

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

  /// 在 isolate 中执行；引号内的逗号由状态机处理。
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
    var row = <String>[];
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
      } else if (c == '\n') {
        row.add(field.toString());
        rows.add(row);
        field.clear();
        // 不能用 row.clear()：rows 里是同一个 List 引用，会清空历史行。
        row = <String>[];
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
