import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/comments/comment_item.dart';
import 'package:kazumi/pages/info/info_episode_comments.dart';

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

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('shows the inline skeleton while the first request runs',
      (tester) async {
    await tester.pumpWidget(_wrap(const InfoEpisodeComments(
      comments: [],
      isLoading: true,
      hasFailed: false,
      onRetry: _noop,
    )));

    expect(find.text('本集还没有讨论'), findsNothing);
    expect(find.text('讨论暂时未能加载'), findsNothing);
  });

  testWidgets('offers a retry when the request failed', (tester) async {
    var retries = 0;
    await tester.pumpWidget(_wrap(InfoEpisodeComments(
      comments: const [],
      isLoading: false,
      hasFailed: true,
      onRetry: () => retries++,
    )));
    await tester.pumpAndSettle();

    expect(find.text('讨论暂时未能加载'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    expect(retries, 1);
  });

  testWidgets('reads as empty when the episode has no discussion',
      (tester) async {
    await tester.pumpWidget(_wrap(const InfoEpisodeComments(
      comments: [],
      isLoading: false,
      hasFailed: false,
      onRetry: _noop,
    )));
    await tester.pumpAndSettle();

    expect(find.text('本集还没有讨论'), findsOneWidget);
  });

  testWidgets('renders every comment with its content', (tester) async {
    await tester.pumpWidget(_wrap(InfoEpisodeComments(
      comments: [_comment('第一条讨论'), _comment('第二条讨论')],
      isLoading: false,
      hasFailed: false,
      onRetry: _noop,
    )));
    await tester.pumpAndSettle();

    expect(find.text('第一条讨论', findRichText: true), findsOneWidget);
    expect(find.text('第二条讨论', findRichText: true), findsOneWidget);
    expect(find.text('已显示全部 2 条讨论 · 来自 Bangumi'), findsOneWidget);
    expect(find.text('本集还没有讨论'), findsNothing);
  });

  testWidgets('keeps the loaded comments when a later refresh fails',
      (tester) async {
    await tester.pumpWidget(_wrap(InfoEpisodeComments(
      comments: [_comment('还在的讨论')],
      isLoading: false,
      hasFailed: true,
      onRetry: _noop,
    )));
    await tester.pumpAndSettle();

    expect(find.text('还在的讨论', findRichText: true), findsOneWidget);
    expect(find.text('讨论暂时未能加载'), findsNothing);
  });
}

void _noop() {}
