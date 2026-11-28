import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:kazumi/modules/bangumi/bangumi_data_snapshot.dart';
import 'package:kazumi/modules/bangumi/site_schedule.dart';
import 'package:kazumi/utils/anime_season.dart';

class TimelineWeekSchedule extends ChangeNotifier with WidgetsBindingObserver {
  TimelineWeekSchedule({
    required this.selectedSeason,
    required this.buildWeek,
    this.now = DateTime.now,
  });

  final DateTime Function() selectedSeason;
  final Map<int, Map<String, SiteSchedule>> Function(DateTime monday) buildWeek;
  final DateTime Function() now;

  DateTime? _today;
  DateTime get today => _today!;
  DateTime? _monday;
  Map<int, Map<String, SiteSchedule>> _entries = const {};
  Iterable<int> get ids => _entries.keys;
  bool get isCurrentSeason => isSameSeason(selectedSeason(), today);
  Timer? _midnight;
  bool _foreground = true;

  void start() {
    final binding = WidgetsBinding.instance;
    final state = binding.lifecycleState;
    _foreground =
        state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    binding.addObserver(this);
    _syncClock();
  }

  void refresh() => _syncClock(force: true);

  SiteSchedule? scheduleFor(int bgmId, int day) {
    final monday = _monday;
    final dates = _entries[bgmId];
    if (monday == null || dates == null || !isCurrentSeason) return null;
    // 优先精确日期，兼容日本深夜档换算到本地后跨到邻日。
    for (final delta in const [0, 1, -1]) {
      final date = _localDay(monday, day + delta);
      final schedule = dates[localDateKey(date)];
      if (schedule != null) return schedule;
    }
    return null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _syncClock();
    } else if (state != AppLifecycleState.inactive) {
      _foreground = false;
      _midnight?.cancel();
    }
  }

  @override
  void dispose() {
    _midnight?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _syncClock({bool force = false}) {
    final instant = now().toLocal();
    final date = _localDay(instant, 0);
    final monday = isSameSeason(selectedSeason(), date)
        ? _localDay(date, DateTime.monday - date.weekday)
        : null;
    final shouldBuild = monday != _monday || (force && monday != null);
    final changedDay = date != _today;
    _today = date;
    if (shouldBuild) {
      _entries = monday == null ? const {} : buildWeek(monday);
      _monday = monday;
    }
    _midnight?.cancel();
    if (_foreground) {
      _midnight = Timer(_localDay(date, 1).difference(instant), _syncClock);
    }
    if (changedDay || shouldBuild) notifyListeners();
  }

  static DateTime _localDay(DateTime date, int offset) =>
      DateTime(date.year, date.month, date.day + offset);
}
