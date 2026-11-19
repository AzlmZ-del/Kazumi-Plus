import 'dart:convert';

/// bangumi-data 的离线精简产物。
///
/// 只保留时间表需要的字段：条目身份、中文名、放送区间、条目级广播规则与
/// 各平台的循环规则。全量 data.json 有 8 MB 且多数站点与时间表无关，
/// 落盘前必须先瘦身。
class BangumiDataSnapshot {
  const BangumiDataSnapshot({
    required this.fetchedAt,
    required this.items,
    required this.sites,
  });

  final DateTime fetchedAt;
  final List<BangumiDataItem> items;

  /// 平台字典，即 bangumi-data 的 `siteMeta`。
  final Map<String, BangumiSiteMeta> sites;

  static const int version = 1;

  String encode() => jsonEncode({
    'v': version,
    'at': fetchedAt.millisecondsSinceEpoch,
    'sites': {
      for (final entry in sites.entries) entry.key: entry.value.toJson(),
    },
    'items': [for (final item in items) item.toJson()],
  });

  static BangumiDataSnapshot? decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      if (decoded['v'] != version) return null;
      final at = decoded['at'];
      if (at is! int) return null;
      final rawSites = decoded['sites'];
      final sites = <String, BangumiSiteMeta>{};
      if (rawSites is Map) {
        rawSites.forEach((key, value) {
          if (key is! String || value is! Map) return;
          final meta = BangumiSiteMeta.fromJson(value.cast<String, dynamic>());
          if (meta != null) sites[key] = meta;
        });
      }
      final rawItems = decoded['items'];
      final items = <BangumiDataItem>[];
      if (rawItems is List) {
        for (final entry in rawItems) {
          if (entry is! Map) continue;
          final item = BangumiDataItem.fromJson(entry.cast<String, dynamic>());
          if (item != null) items.add(item);
        }
      }
      if (items.isEmpty) return null;
      return BangumiDataSnapshot(
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(at),
        items: items,
        sites: sites,
      );
    } catch (_) {
      return null;
    }
  }
}

class BangumiDataItem {
  const BangumiDataItem({
    required this.bgmId,
    required this.title,
    required this.titleZh,
    this.begin,
    this.end,
    this.broadcastRule,
    this.sites = const [],
  });

  /// Bangumi 条目 ID，与 Kazumi 内部的番剧 ID 是同一体系。
  final int bgmId;
  final String title;

  /// 简体优先、繁体兜底的中文标题；没有译文时为空串。
  final String titleZh;

  final DateTime? begin;
  final DateTime? end;

  /// 条目级广播规则，代表「正片播出时刻」，与各平台时间可能不同。
  final String? broadcastRule;

  final List<BangumiSiteEntry> sites;

  String displayTitle(String fallback) =>
      titleZh.isNotEmpty ? titleZh : (title.isNotEmpty ? title : fallback);

  Map<String, dynamic> toJson() => {
    'i': bgmId,
    't': title,
    'z': titleZh,
    if (begin != null) 'b': formatUtcIso(begin!),
    if (end != null) 'e': formatUtcIso(end!),
    if (broadcastRule != null) 'r': broadcastRule,
    's': [for (final site in sites) site.toJson()],
  };

  static BangumiDataItem? fromJson(Map<String, dynamic> json) {
    final id = json['i'];
    if (id is! int) return null;
    final rawSites = json['s'];
    return BangumiDataItem(
      bgmId: id,
      title: (json['t'] as String?) ?? '',
      titleZh: (json['z'] as String?) ?? '',
      begin: parseUtcIso(json['b']),
      end: parseUtcIso(json['e']),
      broadcastRule: json['r'] as String?,
      sites: [
        if (rawSites is List)
          for (final site in rawSites)
            if (site is Map)
              ?BangumiSiteEntry.fromJson(site.cast<String, dynamic>()),
      ],
    );
  }
}

/// 单条「番剧 × 平台」记录。`rule` 为空表示只有条目、没有精确时刻。
class BangumiSiteEntry {
  const BangumiSiteEntry({required this.site, required this.id, this.rule});

  final String site;
  final String id;
  final String? rule;

  bool get hasTiming => rule != null && rule!.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'n': site,
    'i': id,
    if (rule != null) 'b': rule,
  };

  static BangumiSiteEntry? fromJson(Map<String, dynamic> json) {
    final site = json['n'];
    final id = json['i'];
    if (site is! String || id is! String) return null;
    final rule = json['b'];
    return BangumiSiteEntry(
      site: site,
      id: id,
      rule: rule is String && rule.isNotEmpty ? rule : null,
    );
  }
}

/// 平台字典项：bangumi-data 的 `siteMeta`。
class BangumiSiteMeta {
  const BangumiSiteMeta({
    required this.key,
    required this.title,
    required this.type,
    this.urlTemplate,
    this.regions = const [],
  });

  final String key;
  final String title;

  /// `onair` 才是放送平台；`resource` 是资源站，`info` 是资料站。
  final String type;
  final String? urlTemplate;
  final List<String> regions;

  bool get isOnAir => type == 'onair';

  String? urlFor(String id) {
    final template = urlTemplate;
    if (template == null || template.isEmpty) return null;
    return template.replaceAll('{{id}}', id);
  }

  Map<String, dynamic> toJson() => {
    'k': key,
    't': title,
    'y': type,
    if (urlTemplate != null) 'u': urlTemplate,
    if (regions.isNotEmpty) 'r': regions,
  };

  static BangumiSiteMeta? fromJson(Map<String, dynamic> json) {
    final key = json['k'];
    final title = json['t'];
    if (key is! String || title is! String) return null;
    final regions = json['r'];
    return BangumiSiteMeta(
      key: key,
      title: title,
      type: (json['y'] as String?) ?? '',
      urlTemplate: json['u'] as String?,
      regions: [
        if (regions is List)
          for (final region in regions)
            if (region is String) region,
      ],
    );
  }
}

/// 解析 bangumi-data 规则里的绝对时刻。
///
/// 上游实际只用两种形态：`R/2026-10-07T15:00:00.000Z/P7D` 与裸时间戳，
/// 不实现完整 RFC 5545。
DateTime? parseUtcIso(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}

String formatUtcIso(DateTime value) {
  final utc = value.toUtc();
  final text = utc.toIso8601String();
  return text.endsWith('Z') ? text : '${text}Z';
}

/// 本地日期键（`2026-11-18`），用于把事件按天分桶。
String localDateKey(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '${value.year}-$month-$day';
}
