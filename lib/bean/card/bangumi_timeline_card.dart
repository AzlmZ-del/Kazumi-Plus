import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/modules/bangumi/airing_slot.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';

class BangumiTimelineCard extends StatelessWidget {
  const BangumiTimelineCard({
    super.key,
    required this.bangumiItem,
    required this.showRating,
    required this.onTap,
    this.isWatching = false,
    this.isCollected = false,
    this.compact = false,
    this.airingSlot,
    this.reserveAiring = false,
  });

  final BangumiItem bangumiItem;
  final bool showRating;

  /// 是否「在看」。边框高亮由 [isCollected] 统一控制，这个字段只用于无障碍描述。
  final bool isWatching;

  /// 是否已收藏（任意收藏类型，含在看/想看/看过/搁置/抛弃）。
  ///
  /// 为 true 时卡片边框改用次级色，替代原来左下角的书签图标。
  final bool isCollected;

  final bool compact;

  /// 该番的放送信息；拿不到时为 null，卡片不显示时间 chip。
  final AiringSlot? airingSlot;

  /// 是否给放送信息预留底部一行。
  ///
  /// 由时间线页面统一传入（整列同真同假），而不是卡片自己按 [airingSlot]
  /// 判断：SliverGrid 用统一 mainAxisExtent，同列卡片必须等高，否则
  /// 有 chip 的卡片比没 chip 的高出一截，列表会参差。
  final bool reserveAiring;

  final VoidCallback onTap;

  static final _episodePattern =
      RegExp(r'^\s*([1-9]\d*)\s*[话話集](?=\s*(?:[/／]|$))');

  static const _contentPadding = 12.0;
  static const _cornerRadius = 28.0;
  static const _titleFontSize = 16.0;
  static const _titleLineHeight = 1.5;
  static const _labelFontSize = 12.0;
  static const _labelLineHeight = 4 / 3;
  static const _metadataGap = 8.0;
  static const _ratingIconSize = 16.0;

  /// 评分 chip 的内边距。竖直方向为 0，只留文字本身的高度；
  /// 左右也收到 8，让 chip 更紧凑。
  static const _ratingPadding =
      EdgeInsets.symmetric(horizontal: 8, vertical: 0);

  /// 放送信息 chip 的内边距，比评分 chip 略瘦，避免整行过长。
  static const _chipPadding =
      EdgeInsets.symmetric(horizontal: 8, vertical: 4);

  // Shared by the grid and card to keep their text-scaled heights in sync.
  //
  // 布局对齐参考图：标题（最多两行）→ 评分 + 元信息 → 弹性空间 → 放送 chip。
  //
  // 高度取「文字所需」与「封面 2:3 所需」的较大值：封面是卡片里最高的固定
  // 元素，卡片矮于封面就只能裁封面（cover 模式会裁掉左右两侧，看起来像被
  // 拉长），所以内容区至少要容得下封面。
  static double heightFor(
    TextScaler scaler, {
    bool compact = false,
    bool hasAiring = false,
  }) {
    final titleHeight = scaler.scale(_titleFontSize) * _titleLineHeight * 2;
    final labelHeight = scaler.scale(_labelFontSize) * _labelLineHeight;
    final metaRowHeight =
        math.max(_ratingIconSize + _ratingPadding.vertical, labelHeight);
    final chipRowHeight = hasAiring
        ? math.max(_ratingIconSize + _chipPadding.vertical, labelHeight)
        : 0.0;
    final textHeight =
        titleHeight + _metadataGap + metaRowHeight + chipRowHeight;
    final contentHeight = math.max(textHeight, coverHeightFor(compact));
    return _contentPadding * 2 + contentHeight;
  }

  /// 封面按 Bangumi 原图 2:3 比例算出高度。
  static double coverWidthFor(bool compact) => compact ? 80.0 : 88.0;

  static double coverHeightFor(bool compact) => coverWidthFor(compact) * 3 / 2;

  String _supportingText(String title) {
    // Calendar entries expose episode counts through info.
    final episodes = _episodePattern.firstMatch(bangumiItem.info);
    final tags = bangumiItem.metaTags.isNotEmpty
        ? bangumiItem.metaTags
        : bangumiItem.tags.map((tag) => tag.name);
    final metadata = <String>[
      if (episodes != null) '${episodes.group(1)} 话',
      ...tags
          .map((name) => name.trim())
          .where((name) => name.isNotEmpty)
          .toSet(),
    ];
    if (metadata.isNotEmpty) return metadata.take(3).join(' · ');
    final originalName = bangumiItem.name.trim();
    return originalName != title ? originalName : '';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      // 已收藏的卡片边框用主强调色 primary：secondaryContainer 太淡，
      // 在 surfaceContainerLow 底上几乎看不出边界。
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius:
              const BorderRadius.all(Radius.circular(_cornerRadius)),
          side: isCollected
              ? BorderSide(color: colors.primary, width: 2)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: heightFor(
              MediaQuery.textScalerOf(context),
              compact: compact,
              hasAiring: reserveAiring,
            ),
            child: Padding(
              padding: const EdgeInsets.all(_contentPadding),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildCover(context),
                  SizedBox(width: compact ? 12 : 16),
                  Expanded(child: _buildDetails(context)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetails(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final translatedName = bangumiItem.nameCn.trim();
    final title =
        translatedName.isNotEmpty ? translatedName : bangumiItem.name.trim();
    final supportingText = _supportingText(title);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题在上，最多两行。
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            color: colors.onSurface,
            fontSize: _titleFontSize,
            fontWeight: FontWeight.w700,
            height: _titleLineHeight,
          ),
        ),
        // 评分行紧跟标题，与参考图一致（不是贴底）。
        if (showRating || supportingText.isNotEmpty) ...[
          const SizedBox(height: _metadataGap),
          Row(
            children: [
              if (showRating) _buildRating(context),
              if (showRating && supportingText.isNotEmpty)
                const SizedBox(width: 10),
              if (supportingText.isNotEmpty)
                Expanded(
                  child: Text(
                    supportingText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontSize: _labelFontSize,
                      height: _labelLineHeight,
                    ),
                  ),
                ),
            ],
          ),
        ],
        // 弹性空间：把放送信息压到卡片底部。
        const Spacer(),
        // 底部：放送时刻 + 集数，左对齐。
        // 收藏状态改由卡片边框表达，这里不再放书签角标。
        // chips 直接渲染不做渐入：冷启动时排期磁盘缓存与日历请求并行读，
        // 缓存命中就与列表同帧出现，渐入反而让卡片已实、芯片还淡，观感
        // 不一致；首次无缓存的情况由页面加载动画兜住。
        if (airingSlot != null)
          Row(
            children: [
              _buildAiringChip(context, airingSlot!),
              const SizedBox(width: 8),
              _buildEpisodeChip(context, airingSlot!),
            ],
          ),
      ],
    );
  }

  /// 「18:19 更新」胶囊。
  ///
  /// 参照参考图：浅色胶囊底 + 时钟图标 + 时分 + 「更新」二字。
  Widget _buildAiringChip(BuildContext context, AiringSlot slot) {
    final colors = Theme.of(context).colorScheme;
    return _buildInfoChip(
      context,
      icon: Icons.schedule_rounded,
      label: '${_formatHm(slot.airTime)} 更新',
      background: colors.surfaceContainerHighest,
      foreground: colors.onSurfaceVariant,
      semanticLabel: '放送时间 ${_formatHm(slot.airTime)}',
    );
  }

  /// 「第 5 集」胶囊。
  Widget _buildEpisodeChip(BuildContext context, AiringSlot slot) {
    final colors = Theme.of(context).colorScheme;
    return _buildInfoChip(
      context,
      icon: Icons.format_list_bulleted_rounded,
      label: '第 ${slot.episode} 集',
      background: colors.surfaceContainerHighest,
      foreground: colors.onSurfaceVariant,
      semanticLabel: '第 ${slot.episode} 集',
    );
  }

  Widget _buildInfoChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color background,
    required Color foreground,
    required String semanticLabel,
  }) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.labelMedium?.copyWith(
      fontSize: _labelFontSize,
      height: _labelLineHeight,
      color: foreground,
    );
    return Semantics(
      label: semanticLabel,
      excludeSemantics: true,
      child: Container(
        padding: _chipPadding,
        decoration: ShapeDecoration(
          color: background,
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: _ratingIconSize, color: foreground),
            const SizedBox(width: 4),
            Text(label, maxLines: 1, softWrap: false, style: labelStyle),
          ],
        ),
      ),
    );
  }

  static String _formatHm(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Widget _buildCover(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final imageUrl = bangumiItem.images['large'] ?? '';
    // Bangumi 封面原始比例是 2:3，高度按宽度算出来固定住。
    // 外层 Row 用了 stretch，子项会被拉满卡片高度，所以这里必须自己锁死，
    // 否则卡片一变高封面就被拉长。
    final width = coverWidthFor(compact);
    final height = coverHeightFor(compact);
    return ExcludeSemantics(
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: width,
          height: height,
          child: Hero(
            tag: bangumiItem.id,
            transitionOnUserGestures: true,
            child: ClipRRect(
              borderRadius: const BorderRadius.all(
                  Radius.circular(_cornerRadius - _contentPadding)),
              child: imageUrl.isEmpty
                  ? ColoredBox(
                      color: colors.surfaceContainerHighest,
                      child: Center(
                        child: Icon(Icons.movie_outlined,
                            color: colors.onSurfaceVariant),
                      ),
                    )
                  : NetworkImgLayer(
                      src: imageUrl,
                      width: width,
                      height: height,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRating(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final labelStyle = theme.textTheme.labelMedium?.copyWith(
      fontSize: _labelFontSize,
      height: _labelLineHeight,
    );
    if (bangumiItem.ratingScore <= 0) {
      return Text('暂无评分',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: labelStyle?.copyWith(color: colors.onSurfaceVariant));
    }
    final score = bangumiItem.ratingScore.toStringAsFixed(1);
    return Semantics(
      label: '评分 $score',
      excludeSemantics: true,
      child: Container(
        padding: _ratingPadding,
        decoration: ShapeDecoration(
          color: colors.secondaryContainer,
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_rounded,
                size: _ratingIconSize, color: colors.onSecondaryContainer),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                score,
                maxLines: 1,
                style: labelStyle?.copyWith(
                  color: colors.onSecondaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

