import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:kazumi/bean/widget/collect_button.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/pages/info/info_quick_actions.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:skeletonizer/skeletonizer.dart';

// 视频卡片 - 水平布局
class BangumiInfoCardV extends StatefulWidget {
  const BangumiInfoCardV({
    super.key,
    required this.bangumiItem,
    required this.isLoading,
    required this.showRating,
  });

  final BangumiItem bangumiItem;
  final bool isLoading;
  final bool showRating;

  @override
  State<BangumiInfoCardV> createState() => _BangumiInfoCardVState();
}

class _BangumiInfoCardVState extends State<BangumiInfoCardV> {
  int touchedIndex = -1;
  bool _savingCover = false;

  /// 窄屏下点击评分行，把整块卡片切换成评分透视。
  bool _showVotes = false;

  @override
  void didUpdateWidget(covariant BangumiInfoCardV oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bangumiItem.id != widget.bangumiItem.id) {
      _showVotes = false;
    }
  }

  Future<void> _saveCover() async {
    if (_savingCover) return;
    setState(() => _savingCover = true);
    try {
      await InfoQuickActions.saveCover(context, widget.bangumiItem);
    } finally {
      if (mounted) setState(() => _savingCover = false);
    }
  }

  Widget _quickActionButton({
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 35, height: 35),
      style: IconButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white70,
        disabledBackgroundColor: scheme.primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        // 安卓默认 padded 会把每个按钮的占位撑到 48dp（compact 下 40dp），
        // 于是 35dp 的方块之间只剩 8dp 的间距被触摸区吃成 14dp 左右，
        // 整排还会整体内缩、与下方「在看」按钮左缘错开。
        // 收成 shrinkWrap 后占位即方块本身，间距与左对齐都回到代码写的值。
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget get _quickActionsRow {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _quickActionButton(
          icon: Icons.download_rounded,
          tooltip: _savingCover ? '保存中…' : '保存封面',
          onPressed: _savingCover ? null : _saveCover,
        ),
        const SizedBox(width: 8),
        _quickActionButton(
          icon: Icons.travel_explore_rounded,
          tooltip: '内部浏览',
          onPressed: () =>
              InfoQuickActions.openInternally(context, widget.bangumiItem),
        ),
        const SizedBox(width: 8),
        _quickActionButton(
          icon: Icons.open_in_new_rounded,
          tooltip: '外部打开',
          onPressed: () =>
              InfoQuickActions.openExternally(context, widget.bangumiItem),
        ),
        const SizedBox(width: 8),
        _quickActionButton(
          icon: Icons.share_rounded,
          tooltip: '分享番剧',
          onPressed: () => InfoQuickActions.share(context, widget.bangumiItem),
        ),
      ],
    );
  }

  /// 评分分布柱状图。宽屏侧栏与窄屏全宽面板共用同一份配置，
  /// 柱顶标人数、横轴两行写占比与分数，横竖屏信息保持一致。
  Widget _buildBarChart() {
    final List<int> counts = widget.bangumiItem.votesCount;
    final int total = widget.bangumiItem.votes;
    final int maxCount = counts.isEmpty
        ? 0
        : counts.reduce((a, b) => a > b ? a : b);
    // Y 轴上限必须是真实上限——之前退化成 1，柱子全被顶成满格。
    // 柱顶要写人数，再留 24% 余量，否则最高的那根数字会被裁掉。
    final double chartMaxY = maxCount <= 0 ? 1.0 : maxCount * 1.24;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 10 根柱子平摊可用宽度，柱宽与字号都按这一格的大小缩放，
        // 横屏窄栏里就不会挤成一坨、也不会盖住柱顶数字。
        final double slot = constraints.maxWidth / 10;
        final double barWidth = (slot * 0.6).clamp(5.0, 20.0).toDouble();
        final double countFontSize = (slot * 0.42).clamp(6.5, 9.0).toDouble();
        final double percentFontSize = (slot * 0.34).clamp(5.5, 7.5).toDouble();
        final TextStyle axisStyle = TextStyle(
          fontSize: countFontSize,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
        return BarChart(
          duration: const Duration(milliseconds: 80),
          BarChartData(
            // alignment: BarChartAlignment.spaceEvenly,
            maxY: maxCount > 0 ? chartMaxY : 1,
            borderData: FlBorderData(show: false),
            gridData: FlGridData(show: false),
            barTouchData: BarTouchData(
              touchCallback: (FlTouchEvent event, barTouchResponse) {
                setState(() {
                  if (!event.isInterestedForInteractions ||
                      barTouchResponse == null ||
                      barTouchResponse.spot == null) {
                    touchedIndex = -1;
                    return;
                  }
                  touchedIndex = barTouchResponse.spot!.touchedBarGroupIndex;
                });
              },
              touchTooltipData: BarTouchTooltipData(
                getTooltipColor: (_) =>
                    Theme.of(context).colorScheme.inverseSurface,
                getTooltipItem: (group, groupIndex, rod, rodIndex) {
                  final int count = counts[groupIndex];
                  final double percentage = total == 0
                      ? 0
                      : count / total * 100;
                  return BarTooltipItem(
                    '${percentage.toStringAsFixed(1)}% ($count人)',
                    TextStyle(
                      color: Theme.of(context).colorScheme.onInverseSurface,
                    ),
                  );
                },
              ),
            ),
            barGroups: List<BarChartGroupData>.generate(
              10,
              (i) => BarChartGroupData(
                x: i + 1,
                barRods: [
                  BarChartRodData(
                    toY: counts[i].toDouble(),
                    color: touchedIndex == i
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).disabledColor,
                    width: barWidth,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(3),
                    ),
                    label: BarChartRodLabel(
                      show: counts[i] > 0,
                      text: '${counts[i]}',
                      offset: const Offset(0, 4),
                      style: axisStyle.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
                // showingTooltipIndicators: [0],
              ),
            ),
            titlesData: FlTitlesData(
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  // 横轴两行：占比在上、分数在下。高度按两行字号一起缩放，
                  // 窄栏里字号小了边框也不会留一条空带。
                  reservedSize:
                      (countFontSize * 1.8 + percentFontSize * 1.5 + 8)
                          .clamp(30.0, 46.0)
                          .toDouble(),
                  getTitlesWidget: (value, meta) {
                    final int score = value.toInt();
                    final Widget scoreText = Text(
                      score.toString(),
                      style: axisStyle,
                    );
                    if (score < 1 || score > counts.length) {
                      return SideTitleWidget(
                        meta: meta,
                        space: 10,
                        child: scoreText,
                      );
                    }
                    final double percentage = total == 0
                        ? 0
                        : counts[score - 1] / total * 100;
                    return SideTitleWidget(
                      meta: meta,
                      space: 6,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${percentage.toStringAsFixed(1)}%',
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.visible,
                            style: TextStyle(
                              fontSize: percentFontSize,
                              height: 1.1,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 2),
                          scoreText,
                        ],
                      ),
                    );
                  },
                ),
              ),
              topTitles: const AxisTitles(),
              leftTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
            ),
          ),
        );
      },
    );
  }

  /// 宽屏右侧常驻的评分透视。
  ///
  /// 用 Expanded 而不是固定比例：这里的高度由外层 Row 撑满，
  /// 若再用 AspectRatio(2) 反推宽度，算出来的宽度会超过这一栏实际的
  /// 宽度，柱子被画到卡片外、右侧两根直接看不见。
  Widget get voteBarChart {
    return Flexible(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('  评分透视:'),
          SizedBox(height: 16),
          Expanded(child: _buildBarChart()),
        ],
      ),
    );
  }

  /// 窄屏全宽评分透视面板，顶部一键收起回到番剧信息。
  Widget _votesPanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final String summary = widget.showRating
        ? '${widget.bangumiItem.votes} 人 · ${widget.bangumiItem.ratingScore} 分 · #${widget.bangumiItem.rank}'
        : '*** 人 · *** 分 · ***';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('评分透视', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            IconButton(
              tooltip: '收起点评分',
              onPressed: () => setState(() => _showVotes = false),
              icon: const Icon(Icons.swap_horiz_rounded, size: 20),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildBarChart()),
      ],
    );
  }

  /// 卡片顶部大字标题，固定在翻转区之外，切换评分透视时不跟着翻。
  Widget _titleLine(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () =>
          InfoQuickActions.copyTitle(context, widget.bangumiItem),
      child: Text(
        widget.bangumiItem.nameCn == ''
            ? widget.bangumiItem.name
            : (widget.bangumiItem.nameCn),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
    );
  }

  Widget _infoPanel(BuildContext context, {required bool canToggleVotes}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: AspectRatio(
                  aspectRatio: 0.65,
                  child: LayoutBuilder(
                    builder: (context, boxConstraints) {
                      final double maxWidth = boxConstraints.maxWidth;
                      final double maxHeight = boxConstraints.maxHeight;
                      return Hero(
                        transitionOnUserGestures: true,
                        flightShuttleBuilder:
                            NetworkImgLayer.heroFlightShuttleBuilder,
                        tag: widget.bangumiItem.id,
                        child: NetworkImgLayer(
                          src: widget.bangumiItem.images['large'] ?? '',
                          width: maxWidth,
                          height: maxHeight,
                          fadeInDuration: const Duration(milliseconds: 0),
                          fadeOutDuration: const Duration(milliseconds: 0),
                        ),
                      );
                    },
                  ),
                ),
              ),
              SizedBox(width: 16),
              Flexible(
                child: Skeletonizer(
                  enabled: widget.isLoading,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Shrink under large system font so the collect button
                      // stays inside the fixed-height card.
                      Flexible(
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.only(bottom: 8),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.topLeft,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('放送开始:'),
                                Text(
                                  widget.bangumiItem.airDate == ''
                                      ? '2000-11-11' // Skeleton Loader 占位符
                                      : widget.bangumiItem.airDate,
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                ),
                                SizedBox(height: 8),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: canToggleVotes
                                      ? () => setState(() => _showVotes = true)
                                      : null,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            widget.showRating
                                                ? '${widget.bangumiItem.votes} 人评分:'
                                                : '*** 人评分:',
                                          ),
                                          if (canToggleVotes) ...[
                                            const SizedBox(width: 4),
                                            Icon(
                                              Icons.bar_chart_rounded,
                                              size: 14,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                            ),
                                          ],
                                        ],
                                      ),
                                      if (widget.isLoading)
                                        // Skeleton Loader 占位符
                                        Text(
                                          '10.0 ********',
                                          style: TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                          ),
                                        ),
                                      if (!widget.isLoading)
                                        Row(
                                          children: [
                                            Text(
                                              widget.showRating
                                                  ? '${widget.bangumiItem.ratingScore}'
                                                  : '***',
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.primary,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            RatingBarIndicator(
                                              itemCount: 5,
                                              rating: widget.showRating
                                                  ? widget
                                                            .bangumiItem
                                                            .ratingScore
                                                            .toDouble() /
                                                        2
                                                  : 0,
                                              itemBuilder: (context, index) =>
                                                  Icon(
                                                    Icons.star_rounded,
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.primary,
                                                  ),
                                              itemSize: 20.0,
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ),
                                SizedBox(height: 8),
                                Text('Bangumi Ranked:'),
                                Text(
                                  widget.showRating
                                      ? '#${widget.bangumiItem.rank}'
                                      : '***',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // 视觉上移 5dp：只挪绘制位置，不占布局，
                      // 因此 spaceBetween 分出的空隙不变，「在看」不会被挤动。
                      Transform.translate(
                        offset: const Offset(0, -5),
                        child: _quickActionsRow,
                      ),
                      SizedBox(
                        width: 120,
                        height: 40,
                        child: CollectButton.extend(
                          bangumiItem: widget.bangumiItem,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (widget.showRating &&
                  MediaQuery.sizeOf(context).width >=
                      LayoutBreakpoint.compact['width']! &&
                  !widget.isLoading)
                voteBarChart,
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 宽屏时评分透视已常驻右侧栏，不再提供整块切换。
    final bool canToggleVotes =
        !widget.isLoading &&
        widget.showRating &&
        MediaQuery.sizeOf(context).width < LayoutBreakpoint.compact['width']!;
    final bool showingVotes = _showVotes && canToggleVotes;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 高度自适应：可用高度被压到 300 以下时（矮屏、横屏、系统大字号）
        // 卡片跟着缩，不再硬顶 300 被下面的 TabBar 覆盖；200 以下属收起过程中
        // 的过渡帧，保持 300 交给 AppBar 自己裁剪，避免高度跟着抖动。
        final double available = constraints.maxHeight;
        final double cardHeight = available.isFinite && available >= 200.0
            ? math.min(300.0, available)
            : 300.0;
        return Container(
          height: cardHeight,
          constraints: const BoxConstraints(maxWidth: 950),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题固定在翻转区之外，切换评分透视时它不跟着转。
              _titleLine(context),
              const SizedBox(height: 16),
              Expanded(
                child: TweenAnimationBuilder<double>(
                  // 0 = 番剧信息面，1 = 评分透视面。目标值变了会从当前进度接着转。
                  tween: Tween<double>(begin: 0, end: showingVotes ? 1 : 0),
                  duration: const Duration(milliseconds: 450),
                  curve: Curves.easeInOutCubic,
                  builder: (context, value, child) {
                    // 转过 90° 时换面：每面都只在 ±90° 内，文字始终是正的。
                    final bool showVotesFace = value >= 0.5;
                    final double angle = showVotesFace
                        ? math.pi * (1 - value)
                        : -math.pi * value;
                    return ClipRect(
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, 0.001)
                          ..rotateY(angle),
                        child: showVotesFace
                            ? _votesPanel(context)
                            : _infoPanel(
                                context,
                                canToggleVotes: canToggleVotes,
                              ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
