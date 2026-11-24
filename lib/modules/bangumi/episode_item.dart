class EpisodeInfo {
  int id;
  num episode;
  int type;
  String name;
  String nameCn;

  /// First air date, e.g. `2026-10-01`; may be empty if not yet scheduled.
  String airDate;

  /// Episode synopsis, often including part of the staff list.
  String desc;

  /// Raw duration string, e.g. `00:23:45`.
  String duration;

  /// Duration in seconds, 0 if the API does not provide it.
  int durationSeconds;

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

  /// Prefer the Chinese name, then the original; fall back to the episode label.
  String displayTitle() {
    if (nameCn.trim().isNotEmpty) return nameCn.trim();
    if (name.trim().isNotEmpty) return name.trim();
    return episodeLabel();
  }

  /// Metadata line following the Bangumi site format: the air-date and duration
  /// labels (localized at the call below) joined by ` / `.
  ///
  /// Both values are labeled because a bare `2026-10-01 · 00:23:45` reads as a
  /// single timestamp; missing fields are omitted rather than left unlabeled.
  String metaLine() {
    final parts = <String>[];
    if (airDate.trim().isNotEmpty) parts.add('首播:${airDate.trim()}');
    if (duration.trim().isNotEmpty) parts.add('时长:${duration.trim()}');
    return parts.join(' / ');
  }

  /// Main episodes show as `01`; other types carry a type prefix.
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

  /// Parsed first-air date; returns null when the date is missing or malformed.
  ///
  /// Only `yyyy-MM-dd` is accepted: `DateTime.tryParse` normalizes overflow values
  /// like `2026-13-40` to `2027-02-09` instead of returning null, which would
  /// treat dirty data as a future episode.
  DateTime? parsedAirDate() {
    final raw = airDate.trim();
    if (!_airDatePattern.hasMatch(raw)) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    // The normalized result must echo the input exactly, otherwise it is an overflow or non-Gregorian date.
    if (parsed.year != int.parse(raw.substring(0, 4)) ||
        parsed.month != int.parse(raw.substring(5, 7)) ||
        parsed.day != int.parse(raw.substring(8, 10))) {
      return null;
    }
    return parsed;
  }

  static final RegExp _airDatePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  /// Whether the episode has not aired yet.
  ///
  /// Treat a missing date as already aired: the API returns an empty string for
  /// unscheduled entries, and marking such placeholders as upcoming is misleading.
  bool isUpcoming(DateTime now) {
    final date = parsedAirDate();
    if (date == null) return false;
    final today = DateTime(now.year, now.month, now.day);
    return _dateOnly(date).isAfter(today);
  }

  /// Days until first air; returns null if already aired or the date is invalid.
  int? daysUntilAir(DateTime now) {
    final date = parsedAirDate();
    if (date == null) return null;
    final today = DateTime(now.year, now.month, now.day);
    final days = _dateOnly(date).difference(today).inDays;
    return days > 0 ? days : null;
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  /// Group heading; unknown types are grouped under "Other".
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

extension EpisodeInfoDisplay on EpisodeInfo {
  static String typeLabelOf(int type) => switch (type) {
        0 => '正片',
        1 => 'SP',
        2 => 'OP',
        3 => 'ED',
        _ => '其他',
      };

  String displayNumber(int fallbackEpisode) {
    final value = episode != 0 ? episode : fallbackEpisode;
    if (value is int) return '$value';
    final rounded = value.toInt();
    return value == rounded ? '$rounded' : '$value';
  }

  String badgeLabel(int fallbackEpisode) {
    final code = readType().toUpperCase();
    final number = displayNumber(fallbackEpisode);
    return code.isEmpty ? number : '$code $number';
  }

  /// Named apart from [EpisodeInfo.displayTitle], which instance methods shadow
  /// over extensions and which falls back to the episode label instead.
  String panelTitle(int fallbackEpisode) {
    final translated = nameCn.trim();
    if (translated.isNotEmpty) return translated;
    final original = name.trim();
    if (original.isNotEmpty) return original;
    return '第 ${displayNumber(fallbackEpisode)} 集';
  }

  String? displaySubtitle(int fallbackEpisode) {
    final original = name.trim();
    if (original.isEmpty || original == panelTitle(fallbackEpisode)) {
      return null;
    }
    return original;
  }
}
