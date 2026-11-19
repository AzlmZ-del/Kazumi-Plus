import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/site_schedule.dart';
import 'package:kazumi/pages/timeline/platform_sheet.dart';
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
  ratingScore: 8.1,
  votes: 0,
  votesCount: const [],
  info: '',
);

AgendaEntry _entry(
  int id, {
  int? hour,
  int? minute,
  String? label,
  String nameCn = '',
}) {
  final schedule = hour == null
      ? null
      : SiteSchedule(
          airTime: DateTime(2026, 11, 18, hour, minute ?? 0),
          platforms: const [
            SchedulePlatform(name: '動畫瘋', time: '21:30'),
            SchedulePlatform(name: 'Crunchyroll', time: '21:30'),
          ],
        );
  return AgendaEntry(
    item: _item(id, nameCn: nameCn),
    schedule: schedule,
    episodeLabel: label,
  );
}

Widget _host(
  List<AgendaGroup> groups, {
  void Function(AgendaEntry entry)? onPlatforms,
}) {
  return MaterialApp(
    home: Scaffold(
      body: CustomScrollView(
        slivers: [
          AgendaSliver(
            groups: groups,
            showRating: true,
            collectedIds: const {},
            onTap: (_) {},
            onPlatforms: onPlatforms ?? (_) {},
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('渲染时刻、单集文案与平台行', (tester) async {
    await tester.pumpWidget(
      _host(
        groupAgenda([
          _entry(
            1,
            hour: 20,
            minute: 25,
            label: '第 7 话 · 潜入黑暗斗技场',
            nameCn: '乱世千金倪亚',
          ),
        ]),
      ),
    );
    await tester.pump();

    expect(find.text('20:25'), findsOneWidget);
    expect(find.text('乱世千金倪亚'), findsOneWidget);
    expect(find.text('第 7 话 · 潜入黑暗斗技场'), findsOneWidget);
    expect(find.text('動畫瘋  21:30 · 2个平台'), findsOneWidget);
    // 单条不显示同刻标识。
    expect(find.textContaining('同一时刻'), findsNothing);
  });

  testWidgets('同刻多部显示分组标识', (tester) async {
    await tester.pumpWidget(
      _host(
        groupAgenda([
          _entry(1, hour: 22, minute: 30, nameCn: 'A'),
          _entry(2, hour: 22, minute: 30, nameCn: 'B'),
        ]),
      ),
    );
    await tester.pump();

    expect(find.text('同一时刻 · 2部'), findsOneWidget);
    expect(find.text('22:30'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('缺少档期时显示占位文案而不是空行', (tester) async {
    await tester.pumpWidget(_host(groupAgenda([_entry(1, nameCn: '无档期番')])));
    await tester.pump();

    expect(find.text('本集信息待公布'), findsOneWidget);
    expect(find.text('平台时间未确认'), findsOneWidget);
  });

  testWidgets('圆点与竖线中心对齐，且圆点完全落在时间轴列内不被裁切', (tester) async {
    await tester.pumpWidget(
      _host(groupAgenda([_entry(1, hour: 20, nameCn: 'A')])),
    );
    await tester.pump();

    final dotRect = tester.getRect(
      find.byKey(const ValueKey('agenda-axis-dot')),
    );
    final lineRect = tester.getRect(
      find.byKey(const ValueKey('agenda-axis-line')),
    );
    final columnRect = tester.getRect(
      find.byKey(const ValueKey('agenda-axis-column')),
    );

    // 圆心与线中心必须落在同一个 x 上。
    expect(
      dotRect.center.dx,
      moreOrLessEquals(lineRect.center.dx, epsilon: 0.01),
    );
    // Stack 默认硬裁切：圆点一旦越出列宽就会被切掉一半（曾经的 bug）。
    // 这里断言它完整落在列内，而不只是「布局时算得出来」。
    expect(dotRect.right, lessThanOrEqualTo(columnRect.right + 0.01));
    expect(dotRect.left, greaterThanOrEqualTo(columnRect.left - 0.01));
    expect(dotRect.width, moreOrLessEquals(dotRect.height, epsilon: 0.01));
  });

  testWidgets('纯数字集名不与集数重复（第 8 话 · 08）', (tester) async {
    // EpisodeLabelService 会把 `08` 判为占位符剥掉，这里验证剥掉后的文案。
    await tester.pumpWidget(
      _host(groupAgenda([_entry(1, hour: 20, label: '第 8 话', nameCn: 'A')])),
    );
    await tester.pump();
    expect(find.text('第 8 话'), findsOneWidget);
    expect(find.textContaining('· 08'), findsNothing);
  });

  testWidgets('评分行：星级 + 一位小数分数，与分数同高', (tester) async {
    await tester.pumpWidget(
      _host(groupAgenda([_entry(1, hour: 20, nameCn: 'A')])),
    );
    await tester.pump();

    // 胶囊里的分数用 toStringAsFixed(1)；星级图标与分数在同一行。
    expect(find.text('8.1'), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    final starY = tester.getCenter(find.byIcon(Icons.star_rounded)).dy;
    final scoreY = tester.getCenter(find.text('8.1')).dy;
    expect(starY, moreOrLessEquals(scoreY, epsilon: 2));
  });

  testWidgets('平台行在最后一行，点击回调由页面弹窗处理', (tester) async {
    AgendaEntry? tapped;
    await tester.pumpWidget(
      _host(
        groupAgenda([_entry(1, hour: 20, nameCn: 'A')]),
        onPlatforms: (entry) => tapped = entry,
      ),
    );
    await tester.pump();

    final platformY = tester.getTopLeft(find.text('動畫瘋  21:30 · 2个平台')).dy;
    final ratingY = tester.getTopLeft(find.text('8.1')).dy;
    // 平台行必须在评分行下方。
    expect(platformY, greaterThan(ratingY));
    // 平台行只用文字表达可点，不再挂箭头图标。
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);

    await tester.tap(find.text('動畫瘋  21:30 · 2个平台'));
    await tester.pump();

    // 不再在行内展开，而是把条目交给页面去弹窗。
    expect(tapped?.item.id, 1);
    expect(find.text('Crunchyroll  21:30'), findsNothing);
  });

  testWidgets('评分不再被胶囊包裹', (tester) async {
    await tester.pumpWidget(
      _host(groupAgenda([_entry(1, hour: 20, nameCn: 'A')])),
    );
    await tester.pump();

    // 找到包住分数的最近一个 Container/DecoratedBox，必须没有装饰。
    final scoreFinder = find.text('8.1');
    final containers = find.ancestor(
      of: scoreFinder,
      matching: find.byType(Container),
    );
    for (final element in containers.evaluate()) {
      final widget = element.widget as Container;
      expect(widget.decoration, isNull, reason: '评分不应再有胶囊背景');
      expect(widget.color, isNull, reason: '评分不应再有底色');
    }
  });

  testWidgets('单平台也只显示文字，不带箭头', (tester) async {
    final entry = AgendaEntry(
      item: _item(1, nameCn: 'A'),
      schedule: SiteSchedule(
        airTime: DateTime(2026, 11, 18, 21),
        platforms: const [SchedulePlatform(name: '動畫瘋', time: '21:00')],
      ),
    );
    await tester.pumpWidget(_host(groupAgenda([entry])));
    await tester.pump();

    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    expect(find.text('動畫瘋  21:00'), findsOneWidget);
  });

  testWidgets('没有时刻的组在圆点左边显示「时间待定」', (tester) async {
    await tester.pumpWidget(
      _host(
        groupAgenda([
          _entry(1, hour: 20, nameCn: '有时刻'),
          _entry(2, nameCn: '无时刻'),
        ]),
      ),
    );
    await tester.pump();

    expect(find.text('20:00'), findsOneWidget);
    final pending = find.byKey(const ValueKey('agenda-axis-pending'));
    expect(pending, findsOneWidget);
    // key 挂在 Text 本身上，断言文案直接落在这个 finder 上。
    expect(tester.widget<Text>(pending).data, '时间待定');

    // 占位文字必须在圆点左边（X 更小），不能压到轴线上。
    final pendingRect = tester.getRect(pending);
    final dotRect = tester.getRect(
      find.byKey(const ValueKey('agenda-axis-dot')).last,
    );
    expect(pendingRect.right, lessThanOrEqualTo(dotRect.left));
    // 单行显示，不折行；且窄屏下不能溢出时刻列。
    expect(tester.widget<Text>(pending).maxLines, 1);
  });

  testWidgets('窄屏下「时间待定」不溢出时刻列', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 780 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_host(groupAgenda([_entry(1, nameCn: '无时刻')])));
    await tester.pump();

    expect(tester.takeException(), isNull);
    final pendingRect = tester.getRect(
      find.byKey(const ValueKey('agenda-axis-pending')),
    );
    final columnRect = tester.getRect(
      find.byKey(const ValueKey('agenda-axis-column')),
    );
    expect(pendingRect.left, greaterThanOrEqualTo(columnRect.left - 0.01));
  });

  testWidgets('平台弹窗每个平台带「应用内」「外部浏览器」两个图标', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPlatformSheet(
                context: context,
                item: _item(1, nameCn: 'FX战士久留美'),
                schedule: SiteSchedule(
                  airTime: DateTime(2026, 11, 18, 20, 30),
                  platforms: const [
                    SchedulePlatform(
                      name: '動畫瘋',
                      time: '20:30',
                      url: 'https://ani.gamer.com.tw/animeRef.php?sn=1',
                      regions: ['TW'],
                    ),
                    SchedulePlatform(
                      name: 'Crunchyroll',
                      time: '20:30',
                      url: 'https://crunchyroll.com/a',
                    ),
                    // 没有 url 的平台不该出现图标。
                    SchedulePlatform(name: 'Netflix', time: '20:30'),
                  ],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('播放平台'), findsOneWidget);
    expect(find.text('FX战士久留美 · 3 个平台'), findsOneWidget);
    // 两个有 url 的平台各两个图标，无 url 的只显示「无链接」。
    expect(find.byIcon(Icons.travel_explore_rounded), findsNWidgets(2));
    expect(find.byIcon(Icons.open_in_new_rounded), findsNWidgets(2));
    expect(find.text('无链接'), findsOneWidget);
    expect(find.text('動畫瘋'), findsOneWidget);
    expect(find.text('20:30 · TW'), findsOneWidget);
  });

  testWidgets('时刻与「时间待定」都不被自身段落框裁切', (tester) async {
    await tester.pumpWidget(
      _host(
        groupAgenda([
          _entry(1, hour: 22, minute: 56, nameCn: '有时刻'),
          _entry(2, nameCn: '无时刻'),
        ]),
      ),
    );
    await tester.pump();

    // 渲染宽度必须 ≥ 文字自然宽度：小于就是被裁了（截图里像被白块盖住）。
    double naturalWidth(String text) {
      final painter = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(text: text, style: const TextStyle(fontSize: 20)),
      )..layout();
      return painter.width;
    }

    final timeRect = tester.getRect(find.text('22:56'));
    expect(
      timeRect.width,
      greaterThanOrEqualTo(naturalWidth('22:56') - 0.5),
      reason: '时刻文字被裁切',
    );

    final pendingRect = tester.getRect(
      find.byKey(const ValueKey('agenda-axis-pending')),
    );
    final pendingPainter = TextPainter(
      textDirection: TextDirection.ltr,
      text: const TextSpan(text: '时间待定', style: TextStyle(fontSize: 20)),
    )..layout();
    expect(
      pendingRect.width,
      greaterThanOrEqualTo(pendingPainter.width - 0.5),
      reason: '「时间待定」被裁切',
    );
    // 两者右边缘必须完全对齐：固定文字区 + topRight 对齐的直接结果。
    expect(
      timeRect.right,
      moreOrLessEquals(pendingRect.right, epsilon: 0.01),
      reason: '时刻与「时间待定」右边缘没对齐',
    );
    // 时刻字号必须不小于「时间待定」：CJK 比等宽数字宽，后者要缩才等宽。
    final pendingStyle = tester.widget<Text>(find.text('时间待定')).style!;
    final timeStyle = tester.widget<Text>(find.text('22:56')).style!;
    expect(timeStyle.fontSize, greaterThanOrEqualTo(pendingStyle.fontSize!));
  });

  testWidgets('圆点更大、竖线更粗，且仍完全落在列内', (tester) async {
    await tester.pumpWidget(
      _host(groupAgenda([_entry(1, hour: 22, minute: 56, nameCn: 'A')])),
    );
    await tester.pump();

    final dotRect = tester.getRect(
      find.byKey(const ValueKey('agenda-axis-dot')),
    );
    final lineRect = tester.getRect(
      find.byKey(const ValueKey('agenda-axis-line')),
    );
    final columnRect = tester.getRect(
      find.byKey(const ValueKey('agenda-axis-column')),
    );

    // 圆点直径 6、竖线 1.5：比上一版的 5 / 1.0 更有存在感。
    expect(dotRect.width, moreOrLessEquals(6.0, epsilon: 0.01));
    expect(lineRect.width, moreOrLessEquals(1.5, epsilon: 0.01));
    // 中心仍然对齐。
    expect(
      dotRect.center.dx,
      moreOrLessEquals(lineRect.center.dx, epsilon: 0.01),
    );
    // 放大后也不能越界被裁。
    expect(dotRect.right, lessThanOrEqualTo(columnRect.right + 0.01));
  });

  testWidgets('长标题与长文案不溢出', (tester) async {
    await tester.pumpWidget(
      _host(
        groupAgenda([
          _entry(
            1,
            hour: 20,
            label: '第 7 话 · ${'很长的标题' * 20}',
            nameCn: '很长的番名' * 20,
          ),
        ]),
      ),
    );
    await tester.pump();
    // 溢出会被 Flutter 报成异常，tester 会直接失败。
    expect(tester.takeException(), isNull);
  });
}
