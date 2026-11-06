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
/// 数据从 BangumiExtLinker 的 anime_map.csv 在线获取，精简成两列后
/// 缓存到应用私有目录，每天 0 点后的首次启动刷新一次（app 不在后台
/// 定时唤醒，当日内重启只加载缓存）；获取失败沿用本地缓存。
class BgmAniListMap {
  BgmAniListMap._();

  /// GitHub Pages 地址（直连用）。
  ///
  /// 实测（2026-11-06，`curl --noproxy '*'`）无代理环境下 5/5 全通，
  /// 而 raw.githubusercontent.com 有 1/5 直接连不上（000）——
  /// 没有 VPN 的用户也能拉到，所以直连档用它。
  static const String _csvUrlPages =
      'https://rhilip.github.io/BangumiExtLinker/data/anime_map.csv';

  /// raw.githubusercontent.com 地址（镜像用）。
  ///
  /// 与 Pages 版内容完全一致（同为 3,331,025 字节）。gh-proxy / ghfast 这类
  /// 前缀式镜像只认 GitHub 域名，把 github.io 拼上去会 301 成 `https:/` 后 404，
  /// 因此走镜像时必须换成这个原始地址。
  static const String _csvUrlRaw =
      'https://raw.githubusercontent.com/rhilip/BangumiExtLinker/'
      'master/data/anime_map.csv';

  /// 按「设置 → 网络 → 规则仓库加速」选 CSV 源。
  ///
  /// gitcode 只镜像了 KazumiRules 这一个仓库（路径式），套不到 CSV 上，
  /// 只能退回 Pages 直连。
  static String get _csvUrl => switch (RulesMirror.current) {
        RulesMirror.ghProxy => '${ApiEndpoints.ghProxyMirror}$_csvUrlRaw',
        RulesMirror.ghfast => '${ApiEndpoints.ghfastMirror}$_csvUrlRaw',
        RulesMirror.gitcode || RulesMirror.direct => _csvUrlPages,
      };

  static Map<String, int>? _cache;
  static Future<Map<String, int>>? _loading;
  static DateTime? _lastFetch;
  static String? _etag;

  /// 上次拉取用的加速档位（RulesMirror.name）。切档后要重拉，见 refreshInBackground。
  static String? _lastFetchedSource;

  /// 后台刷新进行中标记，防重入。
  static bool _refreshInFlight = false;

  /// 加载映射表：只读本地缓存，不联网。
  ///
  /// 刷新统一由 [refreshInBackground] 在启动时后台触发，见那里的说明。
  static Future<Map<String, int>> ensureLoaded() {
    final cached = _cache;
    if (cached != null) return Future.value(cached);
    return _loading ??= _load();
  }

  /// 上次拉取是否在 0 点之前（即今天还没刷新过）。
  ///
  /// 只在 [refreshInBackground] 里判定，页面侧不再触发刷新。
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
        _lastFetchedSource = await _readSourceMarker(cacheFile);
      }
    } catch (error, stackTrace) {
      KazumiLogger().w('BgmAniListMap: read cache failed',
          error: error, stackTrace: stackTrace);
    }
    // 注意：这里只读盘，不再联网。刷新统一走 refreshInBackground()，
    // 由启动时在后台触发，避免调用方（时间表首屏）被网络卡住最长 60s。
    _loading = null;
    return _cache ?? const {};
  }

  /// 后台静默刷新映射表（用户 2026-11-06 定）。
  ///
  /// 语义：
  /// - 缓存**永不过期**，读不到就直接读盘，失败也不会清空已有数据；
  /// - **0 点后首次启动**刷新一次；切了「规则仓库加速」档位也刷新一次；
  /// - 成功就覆盖缓存，**失败静默忽略**，不弹提示、不写错误 UI。
  ///
  /// 调用方用 `unawaited(...)` 在启动时触发即可，不要 await。
  static Future<void> refreshInBackground() async {
    if (_refreshInFlight) return;
    final sourceChanged = _lastFetchedSource != null &&
        _lastFetchedSource != RulesMirror.current.name;
    if (!_stale() && !sourceChanged) return;
    _refreshInFlight = true;
    try {
      var response = await _fetchCsv();
      // 304 与空缓存配对会永久锁死（每天 304、永远空映射）：
      // ETag 存在但映射为空时丢弃 If-None-Match 强制全量重拉。
      if (response.statusCode == 304 &&
          (_cache == null || _cache!.isEmpty)) {
        KazumiLogger().w(
            'BgmAniListMap: 304 but cache is empty, refetching without etag');
        _etag = null;
        response = await _fetchCsv();
      }
      if (response.statusCode == 304) {
        // 内容没变：只推进拉取时间，避免每次启动都重拉。
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
      // 原子写：先写临时文件再 rename，避免进程被杀时留下半截 JSON。
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
      // 静默失败：用户无感，下次启动再试。
      KazumiLogger().w('BgmAniListMap: background refresh failed, ignored',
          error: error, stackTrace: stackTrace);
    } finally {
      _refreshInFlight = false;
    }
  }

  /// 记下这次缓存是从哪个加速档拉来的，用于「切档后重拉」。
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
    } catch (_) {
      // 标记写失败只会导致下次多拉一次，不影响功能。
    }
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
    // writeAsString 不会自动建父目录；首次落盘时 anime_schedule/ 还不存在，
    // 桌面端实测会直接 PathNotFoundException（网络拉取成功却写盘炸）。
    final target = Directory('${dir.path}/anime_schedule');
    if (!target.existsSync()) {
      await target.create(recursive: true);
    }
    return File('${target.path}/bgm_anilist_map.json');
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
        // 跳过，行结束由 \n 处理
      } else if (c == '\n') {
        row.add(field.toString());
        rows.add(row);
        field.clear();
        // 注意不能用 row.clear()：rows 里持有的是同一个 List 引用，
        // clear 会把已收集的历史行一起清空（表现为所有行都是空数组，
        // 29205 行 CSV 解析出 0 条映射）。改为每行新建 List。
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
