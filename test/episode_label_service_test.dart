import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
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

    test('同一条目只合并在途加载，不永久跳过', () async {
      var calls = 0;
      final response = Completer<Map<String, String>>();
      final store = EpisodeLabelsStore(
        loader: (id) {
          calls++;
          return response.future;
        },
      );

      final first = store.loadAll([1, 1]);
      await store.loadAll([1]);
      expect(calls, 1);
      response.complete({'2026-11-18': '第 1 话'});
      await first;
      await store.loadAll([1]);
      expect(calls, 2);
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

  group('页面复查与服务层 TTL', () {
    test('有效期内不联网，过期后换成新文案', () async {
      final cache = _CacheFixture();
      cache.episodes = [_episode('旧标题')];
      await cache.store.loadAll([1]);
      expect(cache.store.labels[1], {'2026-11-18': '第 1 话 · 旧标题'});

      cache.episodes = [_episode('新标题')];
      cache.advance(const Duration(minutes: 29));
      await cache.store.loadAll([1]);
      expect(cache.requests, 1);
      expect(cache.changes, 1);

      cache.advance(const Duration(minutes: 1));
      await cache.store.loadAll([1]);
      expect(cache.requests, 2);
      expect(cache.store.labels[1], {'2026-11-18': '第 1 话 · 新标题'});
    });

    test('空结果也遵守有效期，过期后能显示补录的章节', () async {
      final cache = _CacheFixture();
      await cache.store.loadAll([1]);
      expect(cache.store.labels[1], isEmpty);
      cache.episodes = [_episode('后来补录')];
      await cache.store.loadAll([1]);
      expect(cache.requests, 1);

      cache.advance(const Duration(minutes: 30));
      await cache.store.loadAll([1]);
      expect(cache.requests, 2);
      expect(cache.store.labels[1], {'2026-11-18': '第 1 话 · 后来补录'});
    });

    test('刷新失败保留旧文案，下次复查可以重试', () async {
      final cache = _CacheFixture();
      cache.episodes = [_episode('旧标题')];
      await cache.store.loadAll([1]);
      cache.advance(const Duration(minutes: 30));
      cache.fail = true;
      await cache.store.loadAll([1]);
      expect(cache.store.labels[1], {'2026-11-18': '第 1 话 · 旧标题'});
      expect(cache.changes, 1);

      cache.fail = false;
      cache.episodes = [_episode('重试成功')];
      await cache.store.loadAll([1]);
      expect(cache.requests, 3);
      expect(cache.store.labels[1], {'2026-11-18': '第 1 话 · 重试成功'});
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
        EpisodeLabelService.labelFor(const {
          '2026-11-19': '第 8 话 · 别的一天',
        }, airTime),
        isNull,
      );
      expect(
        EpisodeLabelService.labelFor(const {
          '2026-11-17': '第 21 话 · 龟裂',
        }, airTime),
        '第 21 话 · 龟裂',
      );
      expect(
        EpisodeLabelService.labelFor(labels, airTime),
        '第 7 话 · 秘密兵器を作ってみた！',
      );
    });

    test('没有文案或没有时刻时返回 null', () {
      expect(
        EpisodeLabelService.labelFor(null, DateTime(2026, 11, 18)),
        isNull,
      );
      expect(
        EpisodeLabelService.labelFor(const {}, DateTime(2026, 11, 18)),
        isNull,
      );
      expect(EpisodeLabelService.labelFor(labels, null), isNull);
    });
  });
}

EpisodeInfo _episode(String title) => EpisodeInfo(
  id: 1,
  episode: 1,
  type: 0,
  name: '',
  nameCn: title,
  airDate: '2026-11-18',
);

class _CacheFixture {
  DateTime _now = DateTime.utc(2026, 11, 18);
  int requests = 0;
  int changes = 0;
  bool fail = false;
  List<EpisodeInfo> episodes = [];

  late final _service = EpisodeLabelService.inMemory(
    now: () => _now,
    fetchEpisodes: (_) async {
      requests++;
      if (fail) throw StateError('请求失败');
      return episodes;
    },
  );
  late final store = EpisodeLabelsStore(
    loader: _service.load,
    onChanged: () => changes++,
  );

  void advance(Duration duration) => _now = _now.add(duration);
}
