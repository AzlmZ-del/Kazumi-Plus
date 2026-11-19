/// 某番当日的平台放送信息。
///
/// 数据来自 bangumi-data 的 `sites[].broadcast`（RFC 5545 循环规则），
/// 与 Bangumi 日历自带的 `air_weekday` 是两套独立来源。
class SiteSchedule {
  const SiteSchedule({this.airTime, this.platforms = const []});

  static const SiteSchedule empty = SiteSchedule();

  /// 本地时区的主放送时刻；只有平台条目、没有 broadcast 规则时为 null。
  final DateTime? airTime;

  /// 当日可放送的平台，按时刻升序。
  final List<SchedulePlatform> platforms;

  bool get isEmpty => platforms.isEmpty;
  bool get isNotEmpty => platforms.isNotEmpty;
  SchedulePlatform? get primary => platforms.isEmpty ? null : platforms.first;
}

/// 单个平台在某日的放送条目。
class SchedulePlatform {
  const SchedulePlatform({
    required this.name,
    required this.time,
    this.url,
    this.regions = const [],
  });

  /// 平台显示名，取自 bangumi-data 的 `siteMeta[site].title`。
  final String name;

  /// 已格式化的时刻；跨日时带「次日」前缀，如 `次日 00:05`。
  final String time;

  /// 该番在该平台的条目页。
  final String? url;

  /// 该平台可用的地区代码。
  final List<String> regions;

  String get label => '$name  $time';
}
