import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';

void main() {
  group('EpisodeInfo.fromJson', () {
    test('reads every field the episode endpoint returns', () {
      final episode = EpisodeInfo.fromJson(const {
        'id': 1741638,
        'sort': 1.0,
        'type': 0,
        'ep': 1,
        'name': 'FXって、なぁに？',
        'name_cn': 'FX⋯是什么？',
        'airdate': '2026-10-01',
        'duration': '00:23:45',
        'duration_seconds': 1425,
        'desc': '就读初三的福贺久留美某天得知母亲…',
        'comment': 244,
      });

      expect(episode.id, 1741638);
      expect(episode.episode, 1.0);
      expect(episode.type, 0);
      expect(episode.name, 'FXって、なぁに？');
      expect(episode.nameCn, 'FX⋯是什么？');
      expect(episode.airDate, '2026-10-01');
      expect(episode.duration, '00:23:45');
      expect(episode.durationSeconds, 1425);
      expect(episode.desc, '就读初三的福贺久留美某天得知母亲…');
      expect(episode.commentCount, 244);
    });

    test('keeps working when only the legacy fields are present', () {
      final episode = EpisodeInfo.fromJson(const {
        'id': 7,
        'sort': 3,
        'type': 0,
        'name': '第三话',
        'name_cn': '',
      });

      expect(episode.episode, 3);
      expect(episode.airDate, '');
      expect(episode.duration, '');
      expect(episode.durationSeconds, 0);
      expect(episode.commentCount, 0);
    });
  });

  group('EpisodeInfo.displayTitle', () {
    test('prefers the Chinese title', () {
      final episode = EpisodeInfo(
        id: 1,
        episode: 1,
        type: 0,
        name: 'FXって、なぁに？',
        nameCn: 'FX⋯是什么？',
      );
      expect(episode.displayTitle(), 'FX⋯是什么？');
    });

    test('falls back to the original title', () {
      final episode = EpisodeInfo(
        id: 1,
        episode: 1,
        type: 0,
        name: 'FXって、なぁに？',
        nameCn: '',
      );
      expect(episode.displayTitle(), 'FXって、なぁに？');
    });

    test('falls back to the episode label when untitled', () {
      final episode = EpisodeInfo(
        id: 1,
        episode: 5,
        type: 0,
        name: '',
        nameCn: '',
      );
      expect(episode.displayTitle(), '05');
    });
  });

  group('EpisodeInfo.episodeLabel', () {
    test('pads regular episodes', () {
      final episode = EpisodeInfo(
        id: 1,
        episode: 2,
        type: 0,
        name: '',
        nameCn: '',
      );
      expect(episode.episodeLabel(), '02');
    });

    test('prefixes specials', () {
      for (final entry in {1: 'SP', 2: 'OP', 3: 'ED'}.entries) {
        final episode = EpisodeInfo(
          id: 1,
          episode: 1,
          type: entry.key,
          name: '',
          nameCn: '',
        );
        expect(episode.episodeLabel(), '${entry.value} 1');
      }
    });
  });

  group('EpisodeInfo air schedule', () {
    final now = DateTime(2026, 10, 19, 15, 30);

    EpisodeInfo withDate(String date) => EpisodeInfo(
          id: 1,
          episode: 1,
          type: 0,
          name: 'x',
          nameCn: '',
          airDate: date,
        );

    test('treats a later date as upcoming', () {
      final episode = withDate('2026-10-22');
      expect(episode.isUpcoming(now), isTrue);
      expect(episode.daysUntilAir(now), 3);
    });

    test('treats today as already aired regardless of the clock time', () {
      final episode = withDate('2026-10-19');
      expect(episode.isUpcoming(now), isFalse);
      expect(episode.daysUntilAir(now), isNull);
    });

    test('treats a past date as already aired', () {
      final episode = withDate('2026-10-01');
      expect(episode.isUpcoming(now), isFalse);
      expect(episode.daysUntilAir(now), isNull);
    });

    test('treats a missing or malformed date as already aired', () {
      for (final raw in ['', '  ', 'TBD', '2026-13-40']) {
        final episode = withDate(raw);
        expect(episode.parsedAirDate(), isNull, reason: raw);
        expect(episode.isUpcoming(now), isFalse, reason: raw);
        expect(episode.daysUntilAir(now), isNull, reason: raw);
      }
    });
  });

  group('EpisodeInfo.readTypeLabel', () {
    test('groups known types', () {
      String labelFor(int type) => EpisodeInfo(
            id: 1,
            episode: 1,
            type: type,
            name: '',
            nameCn: '',
          ).readTypeLabel();

      expect(labelFor(0), '正片');
      expect(labelFor(1), '特别篇');
      expect(labelFor(2), '主题曲');
      expect(labelFor(3), '主题曲');
      expect(labelFor(9), '其他');
    });
  });
}
