import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_data_snapshot.dart';
import 'package:kazumi/modules/bangumi/site_schedule.dart';
import 'package:kazumi/pages/timeline/timeline_week_schedule.dart';

void main() {
  testWidgets('midnight switches the cache and day lookup to the new week', (
    tester,
  ) async {
    final fixture = _Fixture(DateTime(2026, 11, 29, 23, 59, 59));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final week = fixture.week..start();
    try {
      expect(week.scheduleFor(1, 6)?.airTime, DateTime(2026, 11, 29, 12));
      expect(fixture.builtWeeks, [DateTime(2026, 11, 23)]);

      fixture.now = DateTime(2026, 11, 30);
      await tester.pump(const Duration(seconds: 1));

      expect(week.today, DateTime(2026, 11, 30));
      expect(week.scheduleFor(1, 0)?.airTime, DateTime(2026, 11, 30, 12));
      expect(fixture.builtWeeks, [
        DateTime(2026, 11, 23),
        DateTime(2026, 11, 30),
      ]);

      fixture.now = DateTime(2026, 12, 1);
      await tester.pump(const Duration(days: 1));
      expect(week.today, DateTime(2026, 12, 1));
      expect(week.scheduleFor(1, 1)?.airTime, DateTime(2026, 12, 1, 12));
      expect(fixture.builtWeeks, hasLength(2));
    } finally {
      week.dispose();
    }
  });

  testWidgets('a quarter change within a week preserves the selected quarter', (
    tester,
  ) async {
    final fixture = _Fixture(DateTime(2026, 9, 30, 23, 59, 59));
    final selected = fixture.selected;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final week = fixture.week..start();
    try {
      expect(week.scheduleFor(1, 2)?.airTime, DateTime(2026, 9, 30, 12));

      fixture.now = DateTime(2026, 10, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(week.today, DateTime(2026, 10, 1));
      expect(fixture.selected, selected);
      expect(week.isCurrentSeason, isFalse);
      expect(week.scheduleFor(1, 3), isNull);
      expect(week.ids, isEmpty);
      expect(fixture.builtWeeks, [DateTime(2026, 9, 28)]);

      fixture.selected = fixture.now;
      week.refresh();
      expect(week.isCurrentSeason, isTrue);
      expect(week.scheduleFor(1, 3)?.airTime, DateTime(2026, 10, 1, 12));
      expect(fixture.builtWeeks, [
        DateTime(2026, 9, 28),
        DateTime(2026, 9, 28),
      ]);
    } finally {
      week.dispose();
    }
  });

  testWidgets('resume refreshes a week that changed while the app was paused', (
    tester,
  ) async {
    final fixture = _Fixture(DateTime(2026, 11, 29, 23, 59, 59));
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final week = fixture.week..start();
    try {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      fixture.now = DateTime(2026, 11, 30, 8);
      await tester.pump(const Duration(seconds: 2));
      expect(fixture.builtWeeks, [DateTime(2026, 11, 23)]);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(week.today, DateTime(2026, 11, 30));
      expect(week.scheduleFor(1, 0)?.airTime, DateTime(2026, 11, 30, 12));
      expect(fixture.builtWeeks, [
        DateTime(2026, 11, 23),
        DateTime(2026, 11, 30),
      ]);
    } finally {
      week.dispose();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });
}

class _Fixture {
  _Fixture(this.now) : selected = now;

  DateTime now;
  DateTime selected;
  final builtWeeks = <DateTime>[];

  late final week = TimelineWeekSchedule(
    now: () => now,
    selectedSeason: () => selected,
    buildWeek: (monday) {
      builtWeeks.add(monday);
      return {
        1: {
          for (var day = 0; day < 7; day++)
            localDateKey(
              DateTime(monday.year, monday.month, monday.day + day),
            ): SiteSchedule(
              airTime: DateTime(
                monday.year,
                monday.month,
                monday.day + day,
                12,
              ),
            ),
        },
      };
    },
  );
}
