import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_data_snapshot.dart';
import 'package:kazumi/services/anime_schedule/bangumi_data_service.dart';

void main() {
  group('expandRrule', () {
    final from = DateTime.utc(2026, 11, 16);
    final to = DateTime.utc(2026, 11, 23);

    test('展开 P7D 副本，落在窗口内', () {
      final result = expandRrule('R/2026-10-07T13:00:00.000Z/P7D', from, to);
      expect(result, isNotEmpty);
      for (final entry in result) {
        expect(entry.isBefore(from), isFalse);
        expect(entry.isAfter(to), isFalse);
        expect(entry.toIso8601String(), endsWith('13:00:00.000Z'));
      }
    });

    test('保留恰好命中起点的事件，只跳过起点之前的事件', () {
      const rule = 'R/2026-11-09T00:00:00.000Z/P7D';
      const microsecond = Duration(microseconds: 1);

      expect(expandRrule(rule, from.subtract(microsecond), to), [from, to]);
      expect(expandRrule(rule, from, to), [from, to]);
      expect(expandRrule(rule, from.add(microsecond), to), [to]);
    });

    test('锚点晚于窗口时返回空表', () {
      expect(expandRrule('R/2026-12-01T13:00:00.000Z/P7D', from, to), isEmpty);
    });

    test('非循环规则不展开', () {
      expect(expandRrule('2026-10-07T13:00:00.000Z', from, to), isEmpty);
    });

    test('非法周期不猜测', () {
      expect(expandRrule('R/2026-10-07T13:00:00.000Z/P0D', from, to), isEmpty);
      expect(expandRrule('R/2026-10-07T13:00:00.000Z/PT1H', from, to), isEmpty);
      expect(expandRrule('R/not-a-date/P7D', from, to), isEmpty);
    });

    test('窗口跨越多个周期时逐期展开', () {
      final result = expandRrule(
        'R/2026-10-07T13:00:00.000Z/P7D',
        DateTime.utc(2026, 11, 1),
        DateTime.utc(2026, 11, 30),
      );
      // 锚点 10-07，落进 11 月窗口的是 11-04 / 11-11 / 11-18 / 11-25。
      expect(result.length, 4);
      for (var i = 1; i < result.length; i++) {
        expect(result[i].difference(result[i - 1]).inDays, 7);
      }
    });
  });

  group('BangumiDataSnapshot', () {
    test('编解码保持条目与平台字典', () {
      final snapshot = _sampleSnapshot();
      final decoded = BangumiDataSnapshot.decode(snapshot.encode());
      expect(decoded, isNotNull);
      expect(decoded!.items.length, 1);
      expect(decoded.items.first.bgmId, 646154);
      expect(decoded.items.first.sites.first.site, 'gamer');
      expect(decoded.items.first.sites.first.hasTiming, isTrue);
      expect(decoded.sites['gamer']!.isOnAir, isTrue);
      expect(
        decoded.sites['gamer']!.urlFor('151278'),
        'https://ani.gamer.com.tw/animeRef.php?sn=151278',
      );
    });

    test('版本不符时拒绝旧缓存', () {
      expect(BangumiDataSnapshot.decode('{"v":0,"items":[]}'), isNull);
      expect(BangumiDataSnapshot.decode('not json'), isNull);
    });
  });

  group('pruneBangumiData', () {
    // 2026-10-07 起每周三 22:00(JST)，仍在放送；另一个已完结条目应被丢弃。
    const raw = '''
    {
      "siteMeta": {
        "bangumi": {"title": "番组计划", "type": "info",
          "urlTemplate": "https://bangumi.tv/subject/{{id}}"},
        "gamer": {"title": "動畫瘋", "type": "onair", "regions": ["TW"],
          "urlTemplate": "https://ani.gamer.com.tw/animeRef.php?sn={{id}}"},
        "mikan": {"title": "蜜柑计划", "type": "resource"}
      },
      "items": [
        {"title": "在放送", "titleTranslate": {"zh-Hans": ["在放送 中文"]},
         "begin": "2026-10-07T13:00:00.000Z",
         "broadcast": "R/2026-10-07T13:00:00.000Z/P7D",
         "sites": [
           {"site": "bangumi", "id": "646154"},
           {"site": "gamer", "id": "151278",
            "broadcast": "R/2026-10-07T13:00:00.000Z/P7D"},
           {"site": "mikan", "id": "4062"}
         ]},
        {"title": "已完结", "begin": "2015-04-01T13:00:00.000Z",
         "end": "2015-06-20T13:00:00.000Z",
         "sites": [
           {"site": "bangumi", "id": "111"},
           {"site": "gamer", "id": "222",
            "broadcast": "R/2015-04-01T13:00:00.000Z/P7D"}
         ]},
        {"title": "无平台", "begin": "2026-10-07T13:00:00.000Z",
         "sites": [{"site": "bangumi", "id": "333"}]}
      ]
    }
    ''';

    test('只保留窗口内且有放送平台的条目', () {
      final slim = pruneBangumiData(raw);
      expect(slim, isNotNull);
      final snapshot = BangumiDataSnapshot.decode(slim!)!;
      expect(snapshot.items.map((item) => item.bgmId), [646154]);
      // 资源站不进时间表，已被剥掉。
      expect(snapshot.items.first.sites.map((site) => site.site), ['gamer']);
      expect(snapshot.items.first.titleZh, '在放送 中文');
    });

    test('平台字典保留 onair 的 URL 模板与地区', () {
      final snapshot = BangumiDataSnapshot.decode(pruneBangumiData(raw)!)!;
      expect(snapshot.sites.keys, containsAll(['bangumi', 'gamer', 'mikan']));
      expect(snapshot.sites['gamer']!.regions, ['TW']);
      expect(snapshot.sites['mikan']!.isOnAir, isFalse);
    });

    test('无法解析的输入返回 null', () {
      expect(pruneBangumiData('not json'), isNull);
      expect(pruneBangumiData('{"items":[]}'), isNull);
    });
  });

  group('buildWeek', () {
    test('按本地日期串出当天平台，并带上多平台计数', () {
      final service = BangumiDataService.instance;
      service.debugLoadSnapshot(_realWorldSnapshot());
      // 2026-11-16 是周一，本站按 UTC+8 落桶。
      final week = service.buildWeek(DateTime(2026, 11, 16));
      final days = week[646154];
      expect(days, isNotNull);
      final wednesday = days![localDateKey(DateTime(2026, 11, 18))];
      expect(wednesday, isNotNull);
      expect(wednesday!.platforms.length, 3);
      expect(wednesday.platforms.first.name, 'dアニメストア');
      expect(wednesday.platforms.first.time, '21:00');
      // 只有条目、没有时刻的平台不进档期。
      expect(
        wednesday.platforms.map((platform) => platform.name),
        isNot(contains('Netflix')),
      );
    });

    test('平台时刻落在放送日之后一天时加「次日」前缀', () {
      final service = BangumiDataService.instance;
      service.debugLoadSnapshot(_nextDaySnapshot());
      final week = service.buildWeek(DateTime(2026, 11, 16));
      final monday = week[900001]![localDateKey(DateTime(2026, 11, 16))];
      expect(monday!.platforms.length, 1);
      expect(monday.platforms.first.time, '次日 00:05');
    });

    test('本地周一零点的循环档期不会从本周漏掉', () {
      final monday = DateTime(2026, 11, 16);
      final anchor = monday.toUtc().subtract(const Duration(days: 7));
      final rule = 'R/${anchor.toIso8601String()}/P7D';
      final service = BangumiDataService.instance;
      service.debugLoadSnapshot(
        BangumiDataSnapshot(
          fetchedAt: monday,
          sites: const {
            'gamer': BangumiSiteMeta(key: 'gamer', title: '動畫瘋', type: 'onair'),
          },
          items: [
            BangumiDataItem(
              bgmId: 646154,
              title: '每周一放送',
              titleZh: '',
              broadcastRule: rule,
              sites: [BangumiSiteEntry(site: 'gamer', id: '1', rule: rule)],
            ),
          ],
        ),
      );

      final schedule = service.buildWeek(monday)[646154]?[localDateKey(monday)];
      expect(schedule?.airTime, monday);
      expect(schedule?.platforms.single.time, '00:00');
    });

    test('窗口外的日期不出现在结果里', () {
      final service = BangumiDataService.instance;
      service.debugLoadSnapshot(_realWorldSnapshot());
      // 下一周同一部番仍然在放送，说明展开不是只算了一次。
      final nextWeek = service.buildWeek(DateTime(2026, 11, 23));
      final wednesday = nextWeek[646154]![localDateKey(DateTime(2026, 11, 25))];
      expect(wednesday, isNotNull);
      expect(wednesday!.platforms.length, 3);
    });
  });

  group('buildWeek 完结过滤', () {
    test('已完结的条目不再展开循环规则', () {
      final service = BangumiDataService.instance;
      service.debugLoadSnapshot(_endedSnapshot());
      // 循环规则本身会算出 11-18，但条目 2026-06 就完结了。
      final week = service.buildWeek(DateTime(2026, 11, 16));
      expect(week.containsKey(900002), isFalse);
    });
  });
}

/// 2026-10-07 起每周三 21:00(本地) 更新，5 个平台有精确时刻、1 个只有条目。
BangumiDataSnapshot _realWorldSnapshot() {
  const rule = 'R/2026-10-07T13:00:00.000Z/P7D';
  return BangumiDataSnapshot(
    fetchedAt: DateTime.utc(2026, 11, 18, 12),
    sites: const {
      'danime': BangumiSiteMeta(key: 'danime', title: 'dアニメストア', type: 'onair'),
      'gamer': BangumiSiteMeta(key: 'gamer', title: '動畫瘋', type: 'onair'),
      'crunchyroll': BangumiSiteMeta(
        key: 'crunchyroll',
        title: 'Crunchyroll',
        type: 'onair',
      ),
      'netflix': BangumiSiteMeta(
        key: 'netflix',
        title: 'Netflix',
        type: 'onair',
      ),
    },
    items: const [
      BangumiDataItem(
        bgmId: 646154,
        title: '世界最強の魔女、始めました',
        titleZh: '世界最强的魔女，就此开始',
        broadcastRule: rule,
        sites: [
          BangumiSiteEntry(site: 'danime', id: '29300', rule: rule),
          BangumiSiteEntry(site: 'gamer', id: '151278', rule: rule),
          BangumiSiteEntry(site: 'crunchyroll', id: 'GT00384009', rule: rule),
          // 只有条目、没有时刻。
          BangumiSiteEntry(site: 'netflix', id: '8170001'),
        ],
      ),
    ],
  );
}

/// 循环规则还在，但条目已经完结。
BangumiDataSnapshot _endedSnapshot() {
  const rule = 'R/2026-04-08T13:00:00.000Z/P7D';
  return BangumiDataSnapshot(
    fetchedAt: DateTime.utc(2026, 11, 18, 12),
    sites: const {
      'danime': BangumiSiteMeta(key: 'danime', title: 'dアニメストア', type: 'onair'),
    },
    items: [
      BangumiDataItem(
        bgmId: 900002,
        title: '已完结',
        titleZh: '',
        begin: DateTime.utc(2026, 4, 8),
        end: DateTime.utc(2026, 6, 24),
        broadcastRule: rule,
        sites: const [
          BangumiSiteEntry(site: 'danime', id: '40001', rule: rule),
        ],
      ),
    ],
  );
}

/// 正片 23:00 播出，平台档期落在次日 00:05。
BangumiDataSnapshot _nextDaySnapshot() {
  return BangumiDataSnapshot(
    fetchedAt: DateTime.utc(2026, 11, 18, 12),
    sites: const {
      'danime': BangumiSiteMeta(key: 'danime', title: 'dアニメストア', type: 'onair'),
    },
    items: const [
      BangumiDataItem(
        bgmId: 900001,
        title: '深夜档',
        titleZh: '',
        broadcastRule: 'R/2026-10-05T15:00:00.000Z/P7D',
        sites: [
          BangumiSiteEntry(
            site: 'danime',
            id: '30001',
            rule: 'R/2026-10-05T16:05:00.000Z/P7D',
          ),
        ],
      ),
    ],
  );
}

BangumiDataSnapshot _sampleSnapshot() {
  return BangumiDataSnapshot(
    fetchedAt: DateTime.utc(2026, 11, 18, 12),
    sites: const {
      'gamer': BangumiSiteMeta(
        key: 'gamer',
        title: '動畫瘋',
        type: 'onair',
        urlTemplate: 'https://ani.gamer.com.tw/animeRef.php?sn={{id}}',
        regions: ['TW'],
      ),
      'mikan': BangumiSiteMeta(key: 'mikan', title: '蜜柑计划', type: 'resource'),
    },
    items: const [
      BangumiDataItem(
        bgmId: 646154,
        title: '世界最強の魔女、始めました',
        titleZh: '世界最强的魔女，就此开始',
        begin: null,
        broadcastRule: 'R/2026-10-07T13:00:00.000Z/P7D',
        sites: [
          BangumiSiteEntry(
            site: 'gamer',
            id: '151278',
            rule: 'R/2026-10-07T13:00:00.000Z/P7D',
          ),
        ],
      ),
    ],
  );
}
