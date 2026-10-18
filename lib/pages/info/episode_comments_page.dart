import 'package:flutter/material.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/card/user_comments_card.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/modules/comments/comment_item.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';

/// 打开 [EpisodeCommentsPage] 时通过路由传入的参数。
class EpisodeCommentsArgs {
  const EpisodeCommentsArgs({
    required this.subjectTitle,
    required this.episode,
  });

  /// 所属番剧名，用于页面头部说明这些讨论属于哪部作品。
  final String subjectTitle;

  final EpisodeInfo episode;
}

/// 单集讨论的独立页面。
///
/// 讨论列表不放在剧集行内展开：一集可能有几十条回复，内联会把剧集列表撑得很长，
/// 也会让「回到某一集」变困难。
class EpisodeCommentsPage extends StatefulWidget {
  const EpisodeCommentsPage({
    super.key,
    required this.subjectTitle,
    required this.episode,
    this.commentsLoader,
  });

  final String subjectTitle;
  final EpisodeInfo episode;

  /// 测试用：替换真实请求，避免依赖网络。
  final Future<List<EpisodeCommentItem>> Function()? commentsLoader;

  @override
  State<EpisodeCommentsPage> createState() => _EpisodeCommentsPageState();
}

class _EpisodeCommentsPageState extends State<EpisodeCommentsPage> {
  static const double _maxWidth = 950;

  List<EpisodeCommentItem> _comments = const [];
  bool _isLoading = true;
  bool _hasFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadComments();
    });
  }

  Future<void> _loadComments() async {
    setState(() {
      _isLoading = true;
      _hasFailed = false;
    });
    try {
      final loader = widget.commentsLoader;
      final comments = loader != null
          ? await loader()
          : (await BangumiApi.getBangumiCommentsByEpisodeID(widget.episode.id))
              .commentList;
      if (!mounted) return;
      setState(() {
        _comments = comments;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _hasFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    return Scaffold(
      appBar: SysAppBar(
        title: Text(
          '${episode.episodeLabel()} 讨论',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final gutter = ((constraints.maxWidth - _maxWidth) / 2)
                .clamp(16.0, double.infinity)
                .toDouble();
            return CustomScrollView(
              scrollBehavior: const ScrollBehavior().copyWith(scrollbars: false),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 4),
                  sliver: SliverToBoxAdapter(child: _header(context)),
                ),
                ..._contentSlivers(gutter),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final episode = widget.episode;
    final meta = [
      if (episode.airDate.trim().isNotEmpty) episode.airDate.trim(),
      if (episode.duration.trim().isNotEmpty) episode.duration.trim(),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.subjectTitle.trim().isNotEmpty)
            Text(
              widget.subjectTitle.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 2),
          Text(
            episode.displayTitle(),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              meta,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _contentSlivers(double gutter) {
    if (_isLoading && _comments.isEmpty) {
      return [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 24),
          sliver: SliverList.builder(
            itemCount: 4,
            itemBuilder: (context, _) => const UserCommentsCardBone(),
          ),
        ),
      ];
    }

    if (_hasFailed && _comments.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: GeneralErrorWidget(
            title: '讨论加载失败',
            errMsg: '请检查网络连接后重试。',
            icon: Icons.cloud_off_rounded,
            onRetry: _loadComments,
          ),
        ),
      ];
    }

    if (_comments.isEmpty) {
      return [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: GeneralEmptyState(
            icon: Icons.chat_bubble_outline_rounded,
            title: '本集还没有讨论',
          ),
        ),
      ];
    }

    final theme = Theme.of(context);
    return [
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: gutter),
        sliver: SliverList.separated(
          addAutomaticKeepAlives: false,
          itemCount: _comments.length,
          itemBuilder: (context, index) => UserCommentsCard.episode(
            _comments[index],
            key: ObjectKey(_comments[index]),
          ),
          separatorBuilder: (_, _) => const Divider(
            thickness: 0.5,
            indent: 10,
            endIndent: 10,
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            8,
            gutter,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          child: Text(
            '已显示全部 ${_comments.length} 条讨论 · 来自 Bangumi',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    ];
  }
}
