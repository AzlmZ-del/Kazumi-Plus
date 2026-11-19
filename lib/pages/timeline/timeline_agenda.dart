import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/site_schedule.dart';

/// 时间轴上的一个时刻分组。
///
/// 同一天里放送时刻相同的条目合并成一组，与参考界面「同一时刻 · N部」一致。
class AgendaGroup {
  const AgendaGroup({this.time, required this.entries});

  /// 该组的放送时刻；整组都拿不到时刻时为 null。
  final DateTime? time;

  final List<AgendaEntry> entries;

  bool get isShared => entries.length > 1;

  String get timeLabel {
    final value = time;
    if (value == null) return '';
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

/// 时间轴上的一条番剧。
class AgendaEntry {
  const AgendaEntry({
    required this.item,
    this.schedule,
    this.episodeLabel,
    this.fallbackEpisode,
  });

  final BangumiItem item;

  /// 当日平台档期；没有 bangumi-data 数据时为 null。
  final SiteSchedule? schedule;

  /// 已解析的单集文案，形如 `第 7 话 · 潜入黑暗斗技场`。
  final String? episodeLabel;

  /// 文案缺失时退回 AniList 的集号，只显示「第 N 集」。
  final int? fallbackEpisode;

  /// 单集行的最终文案；三处都没有时给占位语。
  String get episodeLine {
    final label = episodeLabel;
    if (label != null && label.isNotEmpty) return label;
    final episode = fallbackEpisode;
    if (episode != null && episode > 0) return '第 $episode 集';
    return '本集信息待公布';
  }

  String get platformLine {
    final current = schedule;
    final primary = current?.primary;
    if (primary == null) return '平台时间未确认';
    final count = current!.platforms.length;
    return count > 1 ? '${primary.label} · $count个平台' : primary.label;
  }

  DateTime? get time => schedule?.airTime;
}

/// 把一天的条目按放送时刻分桶。
///
/// [items] 的原始顺序（页面排序按钮的结果）只在同一时刻内保留：时间轴一旦
/// 按时刻排列，跨时刻的排序就没有意义了。
List<AgendaGroup> groupAgenda(List<AgendaEntry> entries) {
  final indexed = <(int, AgendaEntry)>[];
  for (var i = 0; i < entries.length; i++) {
    indexed.add((i, entries[i]));
  }
  // List.sort 不稳定，用原始下标兜底，保证同一时刻内沿用页面排序。
  indexed.sort((a, b) {
    final left = a.$2.time;
    final right = b.$2.time;
    if (left == null && right == null) return a.$1.compareTo(b.$1);
    if (left == null) return 1;
    if (right == null) return -1;
    final byTime = left.compareTo(right);
    return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
  });

  final groups = <AgendaGroup>[];
  for (final entry in indexed.map((pair) => pair.$2)) {
    final time = entry.time;
    final key = time == null
        ? null
        : DateTime(time.year, time.month, time.day, time.hour, time.minute);
    if (groups.isNotEmpty && groups.last.time == key) {
      groups.last.entries.add(entry);
    } else {
      groups.add(AgendaGroup(time: key, entries: [entry]));
    }
  }
  return groups;
}

/// 时间表内容区：左侧时刻 + 圆点 + 竖线，右侧封面与文案。
class AgendaSliver extends StatelessWidget {
  const AgendaSliver({
    super.key,
    required this.groups,
    required this.showRating,
    required this.collectedIds,
    required this.onTap,
    required this.onPlatforms,
    this.compact = false,
  });

  final List<AgendaGroup> groups;
  final bool showRating;
  final Set<int> collectedIds;
  final void Function(BangumiItem item) onTap;

  /// 点击条目里的平台行时回调，由页面弹出平台列表。
  final void Function(AgendaEntry entry) onPlatforms;

  final bool compact;

  static const double _dotRadius = 3.0;
  static const double _lineWidth = 1.5;
  static const double _timeGap = 8;
  static const double _groupGap = 4;

  /// 时刻字号。比「时间待定」大，两者宽度才对得齐。
  static const double _timeFontSize = 23;

  /// 「时间待定」的下限：再小就成灰点，读不出来。
  static const double _pendingMinFontSize = 11;

  /// 轴线占用宽度：圆点直径。竖线比它细，不额外占位。
  static const double _axisWidth = _dotRadius * 2;

  /// 只在给定字号下量一次文本宽度。
  static double _measureWidth(TextScaler scaler, String text, double fontSize) {
    final painter =
        TextPainter(
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )
          ..text = TextSpan(
            text: text,
            style: TextStyle(
              fontSize: fontSize,
              // 与渲染时一致：等宽数字让 `23:00` 的宽度稳定可测。
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );
    painter.layout();
    return painter.width;
  }

  /// 算出「时刻」与「时间待定」各自该用多大字号，使两者渲染宽度相等。
  ///
  /// `23:00` 是 5 个半角字符、`时间待定` 是 4 个全角汉字，同字号下后者明显更宽
  /// （20sp 时约 50 vs 80）。这里按实测宽度比反推：时刻放大到 [_timeFontSize]，
  /// 「时间待定」缩到同宽。宽比随字体与文字缩放变化，所以每次都实测，不写死。
  static (double time, double pending) fontSizes(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final timeWidth = _measureWidth(scaler, '00:00', _timeFontSize);
    final pendingWidth = _measureWidth(scaler, '时间待定', _timeFontSize);
    if (pendingWidth <= 0) {
      return (_timeFontSize, _timeFontSize);
    }
    final pending = _timeFontSize * timeWidth / pendingWidth;
    return (_timeFontSize, pending.clamp(_pendingMinFontSize, _timeFontSize));
  }

  /// 时刻列宽度：两种文本等宽后，取任一个即可。
  ///
  /// 曾经写死 62：扣掉圆点与间距后只剩 43px，`22:56` 在 20sp 下要 55px，
  /// 文字被自己的段落框裁掉右侧——看上去就像被白色盖住了一截。
  static double timeColumnWidth(BuildContext context) =>
      textAreaWidth(context) + _axisWidth + _timeGap;

  /// 文字区宽度：两种文本共同的右对齐宽度。
  ///
  /// 靠字号比例只能让宽度「接近」，字体回退、字距、CJK 度量都会带来偏差。
  /// 这里直接给同一个固定宽度让各自右对齐，两段文字的盒子宽度必然相等。
  static double textAreaWidth(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final (timeSize, pendingSize) = fontSizes(context);
    return math
        .max(
          _measureWidth(scaler, '00:00', timeSize),
          _measureWidth(scaler, '时间待定', pendingSize),
        )
        .ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final columnWidth = timeColumnWidth(context);
    final textWidth = textAreaWidth(context);
    final (timeSize, pendingSize) = fontSizes(context);
    return SliverPadding(
      padding: EdgeInsets.only(right: compact ? 12 : 16),
      sliver: SliverList.builder(
        itemCount: groups.length,
        itemBuilder: (context, index) => _AgendaGroupRow(
          group: groups[index],
          columnWidth: columnWidth,
          textWidth: textWidth,
          timeFontSize: timeSize,
          pendingFontSize: pendingSize,
          showRating: showRating,
          collectedIds: collectedIds,
          onTap: onTap,
          onPlatforms: onPlatforms,
          compact: compact,
          gap: index == groups.length - 1 ? 0 : _groupGap,
        ),
      ),
    );
  }
}

class _AgendaGroupRow extends StatelessWidget {
  const _AgendaGroupRow({
    required this.group,
    required this.columnWidth,
    required this.showRating,
    required this.collectedIds,
    required this.onTap,
    required this.onPlatforms,
    required this.compact,
    required this.gap,
    required this.timeFontSize,
    required this.pendingFontSize,
    required this.textWidth,
  });

  final AgendaGroup group;
  final double columnWidth;

  /// 文字区固定宽度，两段文字右对齐到同一盒子里才算真正等宽。
  final double textWidth;
  final bool showRating;
  final Set<int> collectedIds;
  final void Function(BangumiItem item) onTap;
  final void Function(AgendaEntry entry) onPlatforms;
  final bool compact;
  final double gap;

  /// 已按等宽目标算好的字号，见 [AgendaSliver.fontSizes]。
  final double timeFontSize;
  final double pendingFontSize;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 竖线要贯穿整组，需要 Row 的高度先由右侧内容定下来，所以套 IntrinsicHeight：
    // 直接在 SliverList 里用 stretch 会把无限高度约束传给左侧 SizedBox。
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            key: const ValueKey('agenda-axis-column'),
            width: columnWidth,
            child: Stack(
              // 圆点与竖线都留在 Stack 内，靠边距对齐而不是负偏移；
              // 负偏移会被 Stack 默认的 clip 裁掉一半。
              children: [
                // 竖线贯穿整组高度，与下一组的线首尾相接，形成连续时间轴。
                // 右边缘退半个线宽，让线中心与圆点中心落在同一个 x 上。
                Positioned(
                  right: AgendaSliver._dotRadius - AgendaSliver._lineWidth / 2,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    key: const ValueKey('agenda-axis-line'),
                    width: AgendaSliver._lineWidth,
                    color: colors.outlineVariant.withValues(alpha: .55),
                  ),
                ),
                // 圆点右边缘贴住 Stack 的右边界，中心正好落在距右边界
                // dotRadius 处——也就是竖线的中心。
                Positioned(
                  right: 0,
                  // 垂直居中要跟着「这一组实际显示的那行字」的首行高度走：
                  // 时刻与「时间待定」字号不同，行高也就不同，用同一个值会让
                  // 圆点在某一边明显偏离文字中心。
                  top:
                      _lineHeight(
                            context,
                            group.timeLabel.isEmpty
                                ? pendingFontSize
                                : timeFontSize,
                          ) /
                          2 -
                      AgendaSliver._dotRadius,
                  child: Container(
                    key: const ValueKey('agenda-axis-dot'),
                    width: AgendaSliver._dotRadius * 2,
                    height: AgendaSliver._dotRadius * 2,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Padding(
                  // 右边距等于轴线宽度 + 间距，文字因此不会压到轴线。
                  padding: const EdgeInsets.only(
                    right: AgendaSliver._axisWidth + AgendaSliver._timeGap,
                  ),
                  // 固定文字区宽度 + 右对齐：两种文本的盒子宽度完全一致，
                  // 这才是「等宽」——只靠字号比例只能做到接近。
                  child: SizedBox(
                    width: textWidth,
                    child: Align(
                      alignment: Alignment.topRight,
                      child: group.timeLabel.isEmpty
                          ? Text(
                              '时间待定',
                              key: const ValueKey('agenda-axis-pending'),
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(
                                fontSize: pendingFontSize,
                                height: _timeRowHeightFactor,
                                fontWeight: FontWeight.w400,
                                color: colors.primary,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            )
                          : Text(
                              group.timeLabel,
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(
                                fontSize: timeFontSize,
                                height: _timeRowHeightFactor,
                                fontWeight: FontWeight.w400,
                                color: colors.primary,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                left: AgendaSliver._timeGap,
                bottom: gap,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (group.isShared)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _SharedTimeBadge(count: group.entries.length),
                    ),
                  for (var i = 0; i < group.entries.length; i++) ...[
                    if (i > 0) const SizedBox(height: 14),
                    _AgendaEntryTile(
                      entry: group.entries[i],
                      showRating: showRating,
                      collected: collectedIds.contains(
                        group.entries[i].item.id,
                      ),
                      compact: compact,
                      onTap: () => onTap(group.entries[i].item),
                      onPlatforms: onPlatforms,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const double _timeRowHeightFactor = 1.25;

  /// 指定字号下的单行行高（已含文字缩放）。
  double _lineHeight(BuildContext context, double fontSize) =>
      MediaQuery.textScalerOf(context).scale(fontSize) * _timeRowHeightFactor;
}

/// 「同一时刻 · 2部」胶囊。
class _SharedTimeBadge extends StatelessWidget {
  const _SharedTimeBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: ShapeDecoration(
        color: colors.surfaceContainerHighest,
        shape: const StadiumBorder(),
      ),
      child: Text(
        '同一时刻 · $count部',
        maxLines: 1,
        style: theme.textTheme.labelMedium?.copyWith(
          fontSize: 12,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _AgendaEntryTile extends StatelessWidget {
  const _AgendaEntryTile({
    required this.entry,
    required this.showRating,
    required this.collected,
    required this.compact,
    required this.onTap,
    required this.onPlatforms,
  });

  final AgendaEntry entry;
  final bool showRating;
  final bool collected;
  final bool compact;
  final VoidCallback onTap;

  /// 点击平台行时回调，由页面弹出平台列表。
  final void Function(AgendaEntry entry) onPlatforms;

  static const double _coverWidth = 84;
  static const double _coverHeight = 126;
  static const double _titleFontSize = 15;
  static const double _labelFontSize = 12.5;
  static const double _ratingIconSize = 16;

  /// 与旧卡片一致的元信息行：`12 话 · TV · 日本`。
  ///
  /// 沿用同一条取值链（info 里的集数 + metaTags/tags），换布局不改数据口径。
  String _supportingText(String title) {
    final episodes = RegExp(
      r'^\s*([1-9]\d*)\s*[话話集](?=\s*(?:[/／]|$))',
    ).firstMatch(entry.item.info);
    final tags = entry.item.metaTags.isNotEmpty
        ? entry.item.metaTags
        : entry.item.tags.map((tag) => tag.name);
    final metadata = <String>[
      if (episodes != null) '${episodes.group(1)} 话',
      ...tags
          .map((name) => name.trim())
          .where((name) => name.isNotEmpty)
          .toSet(),
    ];
    if (metadata.isNotEmpty) return metadata.take(3).join(' · ');
    final originalName = entry.item.name.trim();
    return originalName != title ? originalName : '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final translatedName = entry.item.nameCn.trim();
    final title = translatedName.isNotEmpty
        ? translatedName
        : entry.item.name.trim();
    final supportingText = _supportingText(title);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCover(context),
            SizedBox(width: compact ? 10 : 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: _titleFontSize,
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                      color: collected ? colors.primary : colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    entry.episodeLine,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: _labelFontSize,
                      height: 1.45,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 评分行沿用旧卡片的格式：胶囊评分 + 元信息。
                  if (showRating || supportingText.isNotEmpty)
                    _buildRatingRow(context, supportingText),
                  const SizedBox(height: 4),
                  _buildPlatformRow(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRatingRow(BuildContext context, String supportingText) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      fontSize: _labelFontSize,
      height: 4 / 3,
      color: colors.onSurfaceVariant,
    );
    return Row(
      children: [
        if (showRating) _buildRating(context),
        if (showRating && supportingText.isNotEmpty) const SizedBox(width: 10),
        if (supportingText.isNotEmpty)
          Expanded(
            child: Text(
              supportingText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          ),
      ],
    );
  }

  Widget _buildRating(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final labelStyle = theme.textTheme.labelMedium?.copyWith(
      fontSize: _labelFontSize,
      height: 4 / 3,
    );
    final score = entry.item.ratingScore;
    if (score <= 0) {
      return Text(
        '暂无评分',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: labelStyle?.copyWith(color: colors.onSurfaceVariant),
      );
    }
    final text = score.toStringAsFixed(1);
    return Semantics(
      label: '评分 $text',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.star_rounded,
            size: _ratingIconSize,
            color: colors.tertiary,
          ),
          const SizedBox(width: 4),
          Text(
            text,
            maxLines: 1,
            style: labelStyle?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// 平台行：显示首个平台与数量，点击弹出平台列表页。
  ///
  /// 单独包一层 GestureDetector，避免点它时触发整条的跳转。
  Widget _buildPlatformRow(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = theme.textTheme.bodySmall?.copyWith(
      fontSize: _labelFontSize - .5,
      height: 1.45,
      color: colors.onSurfaceVariant,
    );
    final schedule = entry.schedule;
    final primary = schedule?.primary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onPlatforms(entry),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            primary == null
                ? Icons.help_outline_rounded
                : Icons.play_circle_outline_rounded,
            size: _labelFontSize + 1.5,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              entry.platformLine,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCover(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final url = entry.item.images['large'] ?? '';
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        child: SizedBox(
          width: _coverWidth,
          height: _coverHeight,
          child: url.isEmpty
              ? ColoredBox(
                  color: colors.surfaceContainerHighest,
                  child: Icon(
                    Icons.movie_outlined,
                    color: colors.onSurfaceVariant,
                  ),
                )
              : NetworkImgLayer(
                  src: url,
                  width: _coverWidth,
                  height: _coverHeight,
                ),
        ),
      ),
    );
  }
}
