import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:skeletonizer/skeletonizer.dart';

/// 详情页「剧集」页签。
///
/// 按类型分组展示各集，点击一行就地展开单集简介，避免误触播放。
class InfoEpisodesView extends StatelessWidget {
  const InfoEpisodesView({
    super.key,
    required this.episodes,
    required this.isLoading,
    required this.hasLoaded,
    required this.hasError,
    required this.requiresLogin,
    required this.onRetry,
  });

  static const double _maxWidth = 950;

  /// 分组顺序固定，未知类型统一落到「其他」。
  static const List<String> _groupOrder = ['正片', '特别篇', '主题曲', '其他'];

  final List<EpisodeInfo> episodes;
  final bool isLoading;
  final bool hasLoaded;
  final bool hasError;

  /// 直连模式下未登录时，服务端不会返回 R18 条目的剧集。
  final bool requiresLogin;

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (BuildContext context) {
        return CustomScrollView(
          scrollBehavior: const ScrollBehavior().copyWith(scrollbars: false),
          key: const PageStorageKey<String>('剧集'),
          slivers: <Widget>[
            SliverOverlapInjector(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
            ),
            SliverLayoutBuilder(
              builder: (context, constraints) {
                if (hasError) {
                  return SliverFillRemaining(
                    hasScrollBody: false,
                    child: GeneralErrorWidget(
                      title: '剧集列表加载失败',
                      errMsg: requiresLogin
                          ? '该条目需要登录 Bangumi 后才能查看剧集。'
                          : '请检查网络连接后重试。',
                      onRetry: onRetry,
                      actions: requiresLogin
                          ? [
                              TextButton(
                                onPressed: () => context
                                    .pushNamed('/settings/sync'),
                                child: const Text('去登录'),
                              ),
                            ]
                          : const [],
                    ),
                  );
                }

                if (hasLoaded && episodes.isEmpty) {
                  return SliverFillRemaining(
                    hasScrollBody: false,
                    child: GeneralEmptyState(
                      icon: Icons.format_list_numbered_rounded,
                      title: requiresLogin ? '登录后可查看剧集' : '暂无剧集信息',
                      actions: requiresLogin
                          ? [
                              FilledButton.tonal(
                                onPressed: () =>
                                    context.pushNamed('/settings/sync'),
                                child: const Text('去登录'),
                              ),
                            ]
                          : const [],
                    ),
                  );
                }

                final horizontalPadding =
                    ((constraints.crossAxisExtent - _maxWidth) / 2)
                        .clamp(16.0, double.infinity)
                        .toDouble();

                if (!hasLoaded || isLoading) {
                  return SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      16,
                      horizontalPadding,
                      24,
                    ),
                    sliver: SliverList.builder(
                      itemCount: 5,
                      itemBuilder: (context, _) => const _EpisodeSkeletonRow(),
                    ),
                  );
                }

                final groups = _groupEpisodes(episodes);
                final children = <Widget>[];
                for (final entry in groups.entries) {
                  children.add(_GroupHeader(
                    title: entry.key,
                    count: entry.value.length,
                  ));
                  for (final episode in entry.value) {
                    children.add(_EpisodeRow(episode: episode));
                  }
                }

                return SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    8,
                    horizontalPadding,
                    24,
                  ),
                  sliver: SliverList.list(children: children),
                );
              },
            ),
          ],
        );
      },
    );
  }

  Map<String, List<EpisodeInfo>> _groupEpisodes(List<EpisodeInfo> items) {
    final grouped = <String, List<EpisodeInfo>>{};
    for (final episode in items) {
      grouped.putIfAbsent(episode.readTypeLabel(), () => []).add(episode);
    }
    for (final list in grouped.values) {
      list.sort((a, b) => a.episode.compareTo(b.episode));
    }
    // 保持固定顺序，避免接口返回顺序影响分组位置。
    final ordered = <String, List<EpisodeInfo>>{};
    for (final name in _groupOrder) {
      final list = grouped.remove(name);
      if (list != null && list.isNotEmpty) {
        ordered[name] = list;
      }
    }
    ordered.addAll(grouped);
    return ordered;
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count 集',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _EpisodeRow extends StatefulWidget {
  const _EpisodeRow({required this.episode});

  final EpisodeInfo episode;

  @override
  State<_EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<_EpisodeRow> {
  bool _expanded = false;

  String get _metaLine {
    final parts = <String>[];
    final episode = widget.episode;
    if (episode.airDate.isNotEmpty) {
      parts.add(episode.airDate);
    }
    if (episode.duration.isNotEmpty) {
      parts.add(episode.duration);
    }
    if (episode.commentCount > 0) {
      parts.add('${episode.commentCount} 条讨论');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final episode = widget.episode;
    final hasDesc = episode.desc.trim().isNotEmpty;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: colors.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      child: InkWell(
        onTap: hasDesc
            ? () => setState(() => _expanded = !_expanded)
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 42,
                    child: Text(
                      episode.episodeLabel(),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          episode.displayTitle(),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: colors.onSurface,
                          ),
                        ),
                        if (_metaLine.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            _metaLine,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (hasDesc)
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 20,
                      color: colors.onSurfaceVariant,
                    ),
                ],
              ),
              if (hasDesc && _expanded) ...[
                const SizedBox(height: 10),
                Text(
                  episode.desc,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EpisodeSkeletonRow extends StatelessWidget {
  const _EpisodeSkeletonRow();

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Skeletonizer.zone(
          child: Row(
            children: [
              Bone.text(fontSize: 16, width: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Bone.text(width: 180),
                    const SizedBox(height: 6),
                    Bone.text(fontSize: 11, width: 120),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
