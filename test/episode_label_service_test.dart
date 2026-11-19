import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/anime_schedule/episode_label_service.dart';

void main() {
  group('EpisodeLabelsStore', () {
    test('加载完成后把返回值写进 labels（回归：只刷新不写值）', () async {
      var changes = 0;
      final store = EpisodeLabelsStore(
        loader: (id) async => {'2026-11-18': '第 7 话 · 潜入黑暗斗技场'},
        onChanged: () => changes++,
      );

      await store.loadAll([646154]);

      // 这条断言就是当初发到真机的 bug：请求发出去了，结果没写回状态。
      expect(store.labels[646154], isNotNull);
      expect(store.labels[646154]!['2026-11-18'], '第 7 话 · 潜入黑暗斗技场');
      expect(changes, 1);
    });

    test('并发加载多个条目，全部写入', () async {
      final store = EpisodeLabelsStore(
        loader: (id) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return {'2026-11-18': '第 $id 话'};
        },
      );

      final stopwatch = Stopwatch()..start();
      await store.loadAll([1, 2, 3, 4]);
      stopwatch.stop();

      expect(store.labels.keys, containsAll([1, 2, 3, 4]));
      // 并发而非串行：4 个 20ms 请求应在 60ms 内完成。
      expect(stopwatch.elapsedMilliseconds, lessThan(60));
    });

    test('失败（null）不写入，允许下次重试', () async {
      var attempt = 0;
      final store = EpisodeLabelsStore(
        loader: (id) async {
          attempt++;
          return attempt == 1 ? null : {'2026-11-18': '第 1 话'};
        },
      );

      await store.loadAll([9]);
      expect(store.labels.containsKey(9), isFalse, reason: '失败不该被记成已加载');

      await store.loadAll([9]);
      expect(store.labels[9], isNotNull, reason: '应能重试成功');
      expect(attempt, 2);
    });

    test('抛异常时不卡住后续，且不影响其它条目', () async {
      final store = EpisodeLabelsStore(
        loader: (id) async {
          if (id == 1) throw StateError('boom');
          return {'2026-11-18': '第 $id 话'};
        },
      );

      await expectLater(store.loadAll([1]), throwsA(isA<StateError>()));
      // 异常条目可以重试。
      await store.loadAll([2]);
      expect(store.labels[2], isNotNull);
    });

    test('已加载的条目不会重复请求', () async {
      var calls = 0;
      final store = EpisodeLabelsStore(
        loader: (id) async {
          calls++;
          return {'2026-11-18': '第 1 话'};
        },
      );

      await store.loadAll([1]);
      await store.loadAll([1]);
      expect(calls, 1);
    });

    test('merge 只并缓存，不触发网络', () async {
      var calls = 0;
      final store = EpisodeLabelsStore(
        loader: (id) async {
          calls++;
          return null;
        },
      );

      store.merge({
        1: {'2026-11-18': '第 1 话 · 缓存'},
      });

      expect(store.labels[1]!['2026-11-18'], '第 1 话 · 缓存');
      expect(calls, 0);
    });
  });

  group('labelFor', () {
    const labels = {'2026-11-18': '第 7 话 · 秘密兵器を作ってみた！'};

    test('按 UTC 日优先命中', () {
      final airTime = DateTime(2026, 11, 18, 21).toUtc();
      expect(
        EpisodeLabelService.labelFor(labels, airTime),
        '第 7 话 · 秘密兵器を作ってみた！',
      );
    });

    test('UTC 日未命中时回退 +9 / +8 小时', () {
      final airTime = DateTime(2026, 11, 18, 1, 29).toUtc();
      expect(
        EpisodeLabelService.labelFor(
          const {'2026-11-19': '第 8 话 · 别的一天'},
          airTime,
        ),
        isNull,
      );
      expect(
        EpisodeLabelService.labelFor(
          const {'2026-11-17': '第 21 话 · 龟裂'},
          airTime,
        ),
        '第 21 话 · 龟裂',
      );
      expect(
        EpisodeLabelService.labelFor(labels, airTime),
        '第 7 话 · 秘密兵器を作ってみた！',
      );
    });

    test('没有文案或没有时刻时返回 null', () {
      expect(EpisodeLabelService.labelFor(null, DateTime(2026, 11, 18)), isNull);
      expect(
        EpisodeLabelService.labelFor(const {}, DateTime(2026, 11, 18)),
        isNull,
      );
      expect(EpisodeLabelService.labelFor(labels, null), isNull);
    });
  });
}
