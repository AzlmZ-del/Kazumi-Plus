import 'package:flutter/material.dart';
import 'package:kazumi/bean/card/user_comments_card.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/modules/comments/comment_item.dart';

/// 剧集行内联展开的单集讨论列表。
///
/// 直接复用「吐槽」的 [UserCommentsCard.episode]，版式与之保持一致。
class InfoEpisodeComments extends StatelessWidget {
  const InfoEpisodeComments({
    super.key,
    required this.comments,
    required this.isLoading,
    required this.hasFailed,
    required this.onRetry,
  });

  final List<EpisodeCommentItem> comments;
  final bool isLoading;
  final bool hasFailed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    if (isLoading && comments.isEmpty) {
      return const Column(
        children: [UserCommentsCardBone(), UserCommentsCardBone()],
      );
    }

    if (hasFailed && comments.isEmpty) {
      return GeneralErrorWidget(
        compact: true,
        icon: Icons.cloud_off_rounded,
        title: '讨论暂时未能加载',
        errMsg: '请检查网络后重试。',
        onRetry: onRetry,
        retryText: '重新加载',
      );
    }

    if (comments.isEmpty) {
      return const GeneralEmptyState(
        compact: true,
        icon: Icons.chat_bubble_outline_rounded,
        title: '本集还没有讨论',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in comments)
          UserCommentsCard.episode(item, key: ObjectKey(item)),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Text(
            '已显示全部 ${comments.length} 条讨论 · 来自 Bangumi',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
