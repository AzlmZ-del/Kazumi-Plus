import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/site_schedule.dart';
import 'package:kazumi/pages/timeline/timeline_agenda.dart';

BangumiItem _item(int id, {String nameCn = ''}) => BangumiItem(
  id: id,
  type: 2,
  name: 'name$id',
  nameCn: nameCn,
  summary: '',
  airDate: '2026-10-07',
  airWeekday: 3,
  rank: 0,
  images: const {},
  tags: const [],
  alias: const [],
  ratingScore: 0,
  votes: 0,
  votesCount: const [],
  info: '',
);

AgendaEntry _entry(int id, {int? hour, int? minute, String? label}) {
  final schedule = hour == null
      ? null
      : SiteSchedule(
          airTime: DateTime(2026, 11, 18, hour, minute ?? 0),
          platforms: const [
            SchedulePlatform(name: '動畫瘋', time: '21:30'),
            SchedulePlatform(name: 'Crunchyroll', time: '21:30'),
          ],
        );
  return AgendaEntry(item: _item(id), schedule: schedule, episodeLabel: label);
}

void main() {
  group('groupAgenda', () {
    test('按时刻升序排列，同一时刻合并成一组', () {
      final groups = groupAgenda([
        _entry(1, hour: 22, minute: 30),
        _entry(2, hour: 20, minute: 25),
        _entry(3, hour: 22, minute: 30),
        _entry(4, hour: 21, minute: 0),
      ]);
      expect(groups.length, 3);
      expect(groups[0].timeLabel, '20:25');
      expect(groups[1].timeLabel, '21:00');
      expect(groups[2].timeLabel, '22:30');
      // 同刻两条合并，且保留原顺序。
      expect(groups[2].entries.map((e) => e.item.id), [1, 3]);
      expect(groups[2].isShared, isTrue);
      expect(groups[0].isShared, isFalse);
    });

    test('没有时刻的条目排在最后，单独成组', () {
      final groups = groupAgenda([_entry(1), _entry(2, hour: 9), _entry(3)]);
      expect(groups.length, 2);
      expect(groups.first.timeLabel, '09:00');
      expect(groups.last.time, isNull);
      expect(groups.last.timeLabel, '');
      expect(groups.last.entries.map((e) => e.item.id), [1, 3]);
    });

    test('同一时刻内沿用页面排序（按传入顺序）', () {
      // 页面已按热度排好序，时间轴分组不能打乱同刻条目的相对顺序。
      final groups = groupAgenda([
        _entry(30, hour: 18),
        _entry(10, hour: 18),
        _entry(20, hour: 18),
      ]);
      expect(groups.single.entries.map((e) => e.item.id), [30, 10, 20]);
    });

    test('分钟不同则不合并', () {
      final groups = groupAgenda([
        _entry(1, hour: 20, minute: 25),
        _entry(2, hour: 20, minute: 26),
      ]);
      expect(groups.length, 2);
    });

    test('空输入返回空表', () {
      expect(groupAgenda(const []), isEmpty);
    });
  });

  group('AgendaEntry 文案', () {
    test('单集文案优先，其次集号兜底，最后占位', () {
      final withLabel = _entry(1, hour: 20, label: '第 7 话 · 潜入黑暗斗技场');
      expect(withLabel.episodeLine, '第 7 话 · 潜入黑暗斗技场');

      final withEpisode = AgendaEntry(item: _item(2), fallbackEpisode: 10);
      expect(withEpisode.episodeLine, '第 10 集');

      expect(AgendaEntry(item: _item(3)).episodeLine, '本集信息待公布');
    });

    test('平台行带平台数与时刻，缺失时给未确认', () {
      final entry = _entry(1, hour: 20);
      expect(entry.platformLine, '動畫瘋  21:30 · 2个平台');
      expect(AgendaEntry(item: _item(2)).platformLine, '平台时间未确认');
    });

    test('单平台不带「N个平台」后缀', () {
      final entry = AgendaEntry(
        item: _item(1),
        schedule: SiteSchedule(
          airTime: DateTime(2026, 11, 18, 21),
          platforms: const [SchedulePlatform(name: '動畫瘋', time: '21:00')],
        ),
      );
      expect(entry.platformLine, '動畫瘋  21:00');
    });
  });
}
