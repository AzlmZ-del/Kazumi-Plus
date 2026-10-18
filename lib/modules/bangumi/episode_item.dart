class EpisodeInfo {
  int id;
  num episode;
  int type;
  String name;
  String nameCn;

  /// 首播日期，形如 `2026-10-01`；未定档可能为空串。
  String airDate;

  /// 单集简介，常常包含一部分 STAFF 名单。
  String desc;

  /// 时长原文，形如 `00:23:45`。
  String duration;

  /// 时长秒数，接口未提供时为 0。
  int durationSeconds;

  /// 该集在站内的讨论数。
  int commentCount;

  EpisodeInfo({
    required this.id,
    required this.episode,
    required this.type,
    required this.name,
    required this.nameCn,
    this.airDate = '',
    this.desc = '',
    this.duration = '',
    this.durationSeconds = 0,
    this.commentCount = 0,
  });

  factory EpisodeInfo.fromJson(Map<String, dynamic> json) {
    return EpisodeInfo(
        id: json['id'] ?? 0,
        episode: json['sort'] ?? 0,
        type: json['type'] ?? 0,
        name: json['name'] ?? '',
        nameCn: json['name_cn'] ?? '',
        airDate: json['airdate'] ?? '',
        desc: json['desc'] ?? '',
        duration: json['duration'] ?? '',
        durationSeconds: json['duration_seconds'] ?? 0,
        commentCount: json['comment'] ?? 0);
  }

  factory EpisodeInfo.fromTemplate() {
    return EpisodeInfo(id: 0, episode: 0, type: 0, name: '', nameCn: '');
  }

  void reset() {
    id = 0;
    episode = 0;
    type = 0;
    name = '';
    nameCn = '';
    airDate = '';
    desc = '';
    duration = '';
    durationSeconds = 0;
    commentCount = 0;
  }

  /// 优先中文名，其次原名；两者都没有时退回集数。
  String displayTitle() {
    if (nameCn.trim().isNotEmpty) return nameCn.trim();
    if (name.trim().isNotEmpty) return name.trim();
    return episodeLabel();
  }

  /// 正片显示为 `01`，其余类型带上类型前缀。
  String episodeLabel() {
    final number = episode is int
        ? episode.toString()
        : episode.toStringAsFixed(
            episode == episode.roundToDouble() ? 0 : 1);
    switch (type) {
      case 1:
        return 'SP $number';
      case 2:
        return 'OP $number';
      case 3:
        return 'ED $number';
      default:
        return number.padLeft(2, '0');
    }
  }

  /// 首播日期解析结果；日期缺失或格式非法时返回 null。
  ///
  /// 只接受 `yyyy-MM-dd`：`DateTime.tryParse` 会把 `2026-13-40` 这类溢出值
  /// 规范化成 `2027-02-09` 而不是返回 null，直接用会把脏数据当成未来剧集。
  DateTime? parsedAirDate() {
    final raw = airDate.trim();
    if (!_airDatePattern.hasMatch(raw)) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    // 规范化后必须原样反映输入，否则就是溢出或非公历日期。
    if (parsed.year != int.parse(raw.substring(0, 4)) ||
        parsed.month != int.parse(raw.substring(5, 7)) ||
        parsed.day != int.parse(raw.substring(8, 10))) {
      return null;
    }
    return parsed;
  }

  static final RegExp _airDatePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  /// 是否尚未播出。
  ///
  /// 没有可用日期时按「已播出」处理：接口会给未定档的条目返回空串，
  /// 把这类占位条目标成待播只会造成误读。
  bool isUpcoming(DateTime now) {
    final date = parsedAirDate();
    if (date == null) return false;
    final today = DateTime(now.year, now.month, now.day);
    return _dateOnly(date).isAfter(today);
  }

  /// 距首播还有几天；已播出或日期无效时返回 null。
  int? daysUntilAir(DateTime now) {
    final date = parsedAirDate();
    if (date == null) return null;
    final today = DateTime(now.year, now.month, now.day);
    final days = _dateOnly(date).difference(today).inDays;
    return days > 0 ? days : null;
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  /// 分组标题；未知类型统一归到「其他」。
  String readTypeLabel() {
    switch (type) {
      case 0:
        return '正片';
      case 1:
        return '特别篇';
      case 2:
      case 3:
        return '主题曲';
      default:
        return '其他';
    }
  }

  String readType() {
    switch (type) {
      case 0:
        return 'ep';
      case 1:
        return 'sp';
      case 2:
        return 'op';
      case 3:
        return 'ed';
      default:
        return '';
    }
  }
}
