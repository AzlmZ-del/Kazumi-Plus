import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/modules/comments/comment_item.dart';
import 'package:kazumi/pages/info/episode_comments_page.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getTemporaryPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => path;
}

User _user(String name) => User(
      id: 1,
      username: name,
      nickname: name,
      avatar: UserAvatar.fromJson(const {
        'small': '',
        'medium': '',
        'large': '',
      }),
      sign: '',
      joinedAt: 0,
    );

EpisodeCommentItem _comment(String content) => EpisodeCommentItem(
      comment: EpisodeComment(
        user: _user('tester'),
        comment: content,
        createdAt: 1700000000,
      ),
      replies: const [],
    );

EpisodeInfo _episode({
  int id = 1,
  num episode = 3,
  String nameCn = '第三集',
  String airDate = '2026-10-15',
  String duration = '00:23:45',
  int commentCount = 2,
}) =>
    EpisodeInfo(
      id: id,
      episode: episode,
      type: 0,
      name: 'episode $episode',
      nameCn: nameCn,
      airDate: airDate,
      duration: duration,
      commentCount: commentCount,
    );

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  late Directory directory;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    // SysAppBar touches settings through DesktopWindowConfig, which needs
    // an initialized Hive box.
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('kazumi_ep_comments_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  testWidgets('shows the episode header and its comments', (tester) async {
    await tester.pumpWidget(_wrap(EpisodeCommentsPage(
      subjectTitle: '芙莉莲',
      episode: _episode(),
      commentsLoader: () async => [_comment('第一条讨论'), _comment('第二条讨论')],
    )));
    await tester.pumpAndSettle();

    expect(find.text('03 讨论'), findsOneWidget);
    expect(find.text('芙莉莲'), findsOneWidget);
    expect(find.text('第三集'), findsOneWidget);
    expect(find.text('2026-10-15 · 00:23:45'), findsOneWidget);
    expect(find.text('第一条讨论', findRichText: true), findsOneWidget);
    expect(find.text('第二条讨论', findRichText: true), findsOneWidget);
    expect(find.text('已显示全部 2 条讨论 · 来自 Bangumi'), findsOneWidget);
  });

  testWidgets('shows a skeleton while the request is still running',
      (tester) async {
    final completer = Completer<List<EpisodeCommentItem>>();
    await tester.pumpWidget(_wrap(EpisodeCommentsPage(
      subjectTitle: '芙莉莲',
      episode: _episode(),
      commentsLoader: () => completer.future,
    )));
    await tester.pump();

    expect(find.text('本集还没有讨论'), findsNothing);
    expect(find.text('讨论加载失败'), findsNothing);

    completer.complete(const []);
    await tester.pumpAndSettle();
    expect(find.text('本集还没有讨论'), findsOneWidget);
  });

  testWidgets('offers a retry when the request failed', (tester) async {
    var failures = 0;
    await tester.pumpWidget(_wrap(EpisodeCommentsPage(
      subjectTitle: '芙莉莲',
      episode: _episode(),
      commentsLoader: () async {
        failures++;
        if (failures == 1) throw StateError('offline');
        return [_comment('重试后的讨论')];
      },
    )));
    await tester.pumpAndSettle();

    expect(find.text('讨论加载失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(failures, 2);
    expect(find.text('重试后的讨论', findRichText: true), findsOneWidget);
  });

  testWidgets('reads as empty when the episode has no discussion',
      (tester) async {
    await tester.pumpWidget(_wrap(EpisodeCommentsPage(
      subjectTitle: '芙莉莲',
      episode: _episode(commentCount: 0),
      commentsLoader: () async => const [],
    )));
    await tester.pumpAndSettle();

    expect(find.text('本集还没有讨论'), findsOneWidget);
  });

  testWidgets('hides the subject line when no title is passed',
      (tester) async {
    await tester.pumpWidget(_wrap(EpisodeCommentsPage(
      subjectTitle: '   ',
      episode: _episode(nameCn: ''),
      commentsLoader: () async => [_comment('只有一条')],
    )));
    await tester.pumpAndSettle();

    expect(find.text('03 讨论'), findsOneWidget);
    expect(find.text('只有一条', findRichText: true), findsOneWidget);
  });
}
