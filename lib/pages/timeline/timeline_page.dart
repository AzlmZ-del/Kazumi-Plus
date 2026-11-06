import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/card/bangumi_timeline_card.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/bean/widget/bangumi_mirror_error_widget.dart';
import 'package:kazumi/bean/widget/content_section.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/modules/bangumi/airing_slot.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/timeline/timeline_controller.dart';
import 'package:kazumi/services/anime_schedule/airing_schedule_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/anime_season.dart';

part 'timeline_options.dart';
part 'timeline_week_selector.dart';

class TimelinePage extends StatefulWidget {
  const TimelinePage({
    super.key,
    required this.controller,
  });

  final TimelineController controller;

  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage> {
  TimelineController get _controller => widget.controller;
  late final bool _showRating;

  /// 当前季的放送时刻表：bgmId -> 该番最近一集的放送信息。
  ///
  /// 只对「当前季」拉取：历史季的番不会再有新集，拉排期没有意义，
  /// 而且能省掉切季度时的网络请求。
  Map<int, AiringSlot> _airingSlots = const {};

  /// 正在拉排期的季度，避免重复触发。
  bool _airingLoading = false;

  @override
  void initState() {
    super.initState();
    _showRating = GStorage.getSetting(SettingsKeys.showRating);
    AiringScheduleService.instance.revision.addListener(_onScheduleRevision);
    // 与日历加载并行：磁盘读盘（毫秒级）和 Bangumi 日历请求同时开跑。
    // 日历是网络请求，通常要几百毫秒；把读盘塞进它的等待窗口里，等日历
    // 回来时排期缓存已经就位，chips 就能跟列表同帧出现，不会「先出列表、
    // 再补 chips」。这一步不 await，失败也只是退回原来的行为。
    unawaited(AiringScheduleService.instance.ensureCacheLoaded());
    // 先同步读一次内存缓存，预热已完成的场景首帧就能带 chip。
    _airingSlots = AiringScheduleService.instance
        .resolveCachedLatest(_calendarIds());
    if (_controller.bangumiCalendar.isEmpty) {
      _controller.loadSeason(_controller.selectedDate).then((_) {
        _refreshAiringSlots();
      });
    } else {
      _refreshAiringSlots();
    }
  }

  List<int> _calendarIds() => [
        for (final day in _controller.bangumiCalendar)
          for (final item in day) item.id,
      ];

  @override
  void dispose() {
    AiringScheduleService.instance.revision
        .removeListener(_onScheduleRevision);
    super.dispose();
  }

  /// 拉取当前季番单的放送排期。
  ///
  /// 分两段：
  /// 1) 先用磁盘缓存立刻渲染 chip（本地读盘，毫秒级）；
  /// 2) 再走网络拉最新排期，拿到后覆盖。
  ///
  /// 之前只在 initState 里读一次缓存，但那时 bangumiCalendar 还是空的，
  /// `_calendarIds()` 返回空列表，缓存等于没读——chips 仍要等「日历加载 +
  /// AniList 请求」两段网络，实测冷启动空白 1 秒以上。
  ///
  /// 失败时保持已有的（缓存）数据，卡片不显示空 chip，不影响列表本身。
  Future<void> _refreshAiringSlots() async {
    if (_airingLoading) return;
    if (!isSameSeason(_controller.selectedDate, DateTime.now())) return;
    _airingLoading = true;
    try {
      final bgmIds = _calendarIds();
      // 日历还没就位：不把 _airingLoading 卡住，等日历回来后由调用方再触发。
      if (bgmIds.isEmpty) return;

      // --- 第一段：磁盘缓存，立刻出 chip ---
      // initState 里已经 unawaited 过 ensureCacheLoaded，这里只是保证完成；
      // 若早已读完，这个 await 立即返回，不会多等。
      await AiringScheduleService.instance.ensureCacheLoaded();
      if (!mounted) return;
      final cached =
          AiringScheduleService.instance.resolveCachedLatest(bgmIds);
      if (cached.isNotEmpty && mounted) {
        setState(() => _airingSlots = cached);
      }

      // --- 第二段：网络补齐 ---
      // resolveLatest 会跳过已缓存的 ID，命中的话这一步近乎无请求。
      final slots = await AiringScheduleService.instance.resolveLatest(bgmIds);
      if (!mounted) return;
      if (slots.isNotEmpty) setState(() => _airingSlots = slots);
    } finally {
      _airingLoading = false;
    }
  }

  /// 缓存补齐后自动重算，避免页面停在空状态。
  void _onScheduleRevision() {
    if (!mounted || _airingLoading) return;
    if (_calendarIds().isEmpty) return;
    unawaited(_refreshAiringSlots());
  }

  String _seasonLabel(DateTime date) {
    return '${date.year}年${getSeasonStringByMonth(date.month)}季';
  }

  void _showSeasonBottomSheet(BuildContext context) {
    final now = DateTime.now();
    final years = List.generate(20, (i) => now.year - i);
    showAdaptiveBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      maxHeightFactor: .86,
      builder: (context) => Column(
        children: [
          MaterialBottomSheetHeader(
            title: '放送季度',
            description: '正在查看 ${_seasonLabel(_controller.selectedDate)}',
            onClose: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: ListView.separated(
              padding: materialBottomSheetContentPadding,
              itemCount: years.length,
              separatorBuilder: (_, _) => const SizedBox(height: 24),
              itemBuilder: (context, index) {
                final year = years[index];
                return ContentSection(
                  title: '$year',
                  padding: const EdgeInsets.all(8),
                  child: LayoutBuilder(builder: (context, constraints) {
                    final columns =
                        MediaQuery.textScalerOf(context).scale(14) > 21 ? 2 : 4;
                    return Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final month in [1, 4, 7, 10])
                          SizedBox(
                            width: (constraints.maxWidth - 4 * (columns - 1)) /
                                columns,
                            child: _seasonButton(
                                context, DateTime(year, month), now),
                          ),
                      ],
                    );
                  }),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _seasonButton(BuildContext context, DateTime date, DateTime now) {
    final selected = isSameSeason(_controller.selectedDate, date);
    final colors = Theme.of(context).colorScheme;
    return TextButton(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        backgroundColor:
            selected ? colors.secondaryContainer : Colors.transparent,
        foregroundColor:
            selected ? colors.onSecondaryContainer : colors.onSurface,
      ),
      onPressed: !date.isAfter(now)
          ? () {
              Navigator.of(context).pop();
              // 切季度后重新拉排期：只有切回当前季才会真的发请求。
              setState(() => _airingSlots = const {});
              _controller.loadSeason(date).then((_) {
                _refreshAiringSlots();
              });
            }
          : null,
      child: Text('${getSeasonStringByMonth(date.month)}季'),
    );
  }

  void _showOptions() {
    showAdaptiveBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      maxHeightFactor: .8,
      compactLandscapeMaxHeightFactor: 1,
      builder: (_) => _TimelineOptionsSheet(controller: _controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 7,
      initialIndex: DateTime.now().weekday - 1,
      animationDuration:
          MediaQuery.disableAnimationsOf(context) ? Duration.zero : null,
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      final narrowPortrait = constraints.maxWidth < 600 &&
          constraints.maxHeight > constraints.maxWidth;
      final sidePadding = constraints.maxWidth < 600 ? 16.0 : 24.0;
      final contentWidth =
          (constraints.maxWidth - sidePadding * 2).clamp(0.0, 1280.0);
      final inset = (constraints.maxWidth - contentWidth) / 2;
      final minCardWidth = scaler.scale(16) > 24 ? 440.0 : 340.0;
      final columns =
          ((contentWidth + 12) / (minCardWidth + 12)).floor().clamp(1, 3);
      return Observer(builder: (context) {
        final loading = _controller.isLoading;
        final failed = _controller.isTimeOut;
        final watchingIds = _controller.loadWatchingBangumiIds();
        // 已收藏（任意类型）用于卡片边框高亮，与「只看追番」筛选无关。
        final collectedIds = _controller.loadCollectedBangumiIds();
        final calendar = _controller.filterCalendar(watchingIds);
        final today = DateTime.now();
        final currentSeason = isSameSeason(_controller.selectedDate, today);
        final seasonHeader = narrowPortrait
            ? null
            : _buildSeasonHeader(context,
                loading: loading, compact: constraints.maxHeight < 500);
        // toolbar 压到 50 后，按钮下方只剩 8；这里补 4 的 top padding，
        // 让「按钮底边 → 星期栏」仍然保持 12，与卡片间距一致。
        final weekHeight = _TimelineWeekSelector.heightFor(scaler) + 16;
        final weekSelector = Padding(
          padding: EdgeInsets.fromLTRB(inset, 4, inset, 12),
          child: _TimelineWeekSelector(
            counts: calendar.map((day) => day.length).toList(),
            todayIndex: currentSeason ? today.weekday - 1 : null,
            isLoading: loading || failed,
          ),
        );
        return Scaffold(
          appBar: SysAppBar(
            needTopOffset: false,
            // 按钮高 34，toolbar 高 50 → 上下各留 8。
            // 留白同时决定「按钮上方」和「按钮到星期栏」的距离。
            toolbarHeight: 50,
            title: narrowPortrait
                ? _buildSeasonPicker(context, loading: loading, inAppBar: true)
                : Text(
                    '时间表',
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: _TimelineOptionsButton(
                  availableWidth: constraints.maxWidth,
                  sort: _controller.sort,
                  filterCount: _controller.activeFilterCount,
                  onPressed: _showOptions,
                ),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: LayoutBuilder(
                builder: (context, viewport) => NestedScrollView(
                      // Keep the outer viewport clamped and unstretched so tabs stay fixed.
                      physics: const ClampingScrollPhysics(),
                      scrollBehavior: ScrollConfiguration.of(context).copyWith(
                        overscroll: false,
                        scrollbars: false,
                      ),
                      headerSliverBuilder: (context, innerBoxIsScrolled) => [
                        if (seasonHeader != null)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(inset, 8, inset, 20),
                              child: seasonHeader,
                            ),
                          ),
                        SliverOverlapAbsorber(
                          handle:
                              NestedScrollView.sliverOverlapAbsorberHandleFor(
                                  context),
                          sliver: SliverPersistentHeader(
                            pinned: true,
                            delegate: _WeekHeaderDelegate(
                              height: weekHeight,
                              color: theme.scaffoldBackgroundColor,
                              child: weekSelector,
                            ),
                          ),
                        ),
                      ],
                      body: loading && calendar.every((day) => day.isEmpty)
                          ? _buildLoading(viewport.maxHeight, weekHeight)
                          : failed
                              ? _TimelineScrollView(
                                  slivers: [
                                    SliverPadding(
                                      padding: const EdgeInsets.all(24),
                                      sliver: SliverToBoxAdapter(
                                        child: BangumiMirrorErrorWidget(
                                          onRetry: () {
                                            _controller.loadSeason(
                                                _controller.selectedDate).then((_) {
                                              _refreshAiringSlots();
                                            });
                                          },
                                          onSettingsReturned: () {
                                            if (mounted) setState(() {});
                                          },
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : TabBarView(
                                  children: [
                                    for (var day = 0; day < 7; day++)
                                      _buildDay(
                                        context,
                                        day: day,
                                        items: calendar[day],
                                        watchingIds: watchingIds,
                                        collectedIds: collectedIds,
                                        columns: columns,
                                        inset: inset,
                                        compact: narrowPortrait,
                                      ),
                                  ],
                                ),
                    )),
          ),
        );
      });
    });
  }

  Widget _buildLoading(double viewportHeight, double overlapHeight) {
    return LayoutBuilder(builder: (context, constraints) {
      // Center loading in the full viewport, including the scroll headers.
      final contentHeight =
          (constraints.maxHeight - overlapHeight).clamp(0.0, double.infinity);
      final headerHeight = viewportHeight - contentHeight;
      final bottomInset = headerHeight.clamp(
          0.0, (contentHeight - 48).clamp(0.0, double.infinity));
      return _TimelineScrollView(
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: const Center(child: LoadingIndicator()),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildSeasonPicker(BuildContext context,
      {required bool loading, bool compact = false, bool inAppBar = false}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = _seasonLabel(_controller.selectedDate);
    final style = inAppBar
        ? theme.textTheme.titleMedium
        : compact || MediaQuery.textScalerOf(context).scale(16) > 24
            ? theme.textTheme.titleLarge
            : theme.textTheme.headlineMedium;
    return Semantics(
      label: '切换放送季度，$label',
      button: true,
      enabled: !loading,
      onTap: loading ? null : () => _showSeasonBottomSheet(context),
      excludeSemantics: true,
      child: Tooltip(
        message: '切换放送季度',
        child: InkWell(
          onTap: loading ? null : () => _showSeasonBottomSheet(context),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            // 竖直内边距归零，整体高度由文字行高决定（约 34），
            // 与右侧「热度优先」按钮齐平。
            padding: EdgeInsets.zero,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(label,
                      maxLines: inAppBar ? 1 : null,
                      overflow: inAppBar ? TextOverflow.ellipsis : null,
                      style: style?.copyWith(
                          color: colors.onSurface,
                          fontWeight: FontWeight.w700)),
                ),
                SizedBox(width: inAppBar ? 2 : 6),
                if (inAppBar)
                  const Icon(Icons.expand_more_rounded, size: 18)
                else
                  CircleAvatar(
                    radius: 13,
                    backgroundColor: colors.secondaryContainer,
                    foregroundColor: colors.onSecondaryContainer,
                    child: const Icon(Icons.expand_more_rounded, size: 18),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSeasonHeader(BuildContext context,
      {required bool loading, required bool compact}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final date = _controller.selectedDate;
    final startMonth = ((date.month - 1) ~/ 3) * 3 + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSeasonPicker(context, loading: loading, compact: compact),
        if (!compact)
          Text(
            loading ? '正在加载放送时间表…' : '$startMonth — ${startMonth + 2} 月 · 每周放送',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
      ],
    );
  }

  Widget _buildDay(
    BuildContext context, {
    required int day,
    required List<BangumiItem> items,
    required Set<int> watchingIds,
    required Set<int> collectedIds,
    required int columns,
    required double inset,
    required bool compact,
  }) {
    // SliverGrid 用统一 aspectRatio，所以整列必须按「有 chip」预留高度，
    // 否则同一天里有的卡片带 chip、有的不带，高度会参差。
    final hasAiring = _airingSlots.isNotEmpty;
    final cardHeight = BangumiTimelineCard.heightFor(
        MediaQuery.textScalerOf(context),
        compact: compact,
        hasAiring: hasAiring);
    final rawCalendar = _controller.bangumiCalendar;
    final filteredOut = day < rawCalendar.length && rawCalendar[day].isNotEmpty;
    return _TimelineScrollView(
      key: PageStorageKey('timeline-day-$day'),
      slivers: [
        if (items.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              child: GeneralEmptyState(
                icon: filteredOut
                    ? Icons.filter_alt_off_rounded
                    : Icons.event_available_rounded,
                title: filteredOut ? '没有符合筛选的番剧' : '这一天暂无放送',
                actions: [
                  if (filteredOut)
                    StateActionButton.tonal(
                      onPressed: _controller.clearFilters,
                      text: '清除筛选',
                    ),
                ],
              ),
            ),
          )
        else
          SliverPadding(
            // 底部与卡片间距、星期栏间距统一为 12。
            padding: EdgeInsets.fromLTRB(inset, 0, inset, 12),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                mainAxisExtent: cardHeight,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final item = items[index];
                  return BangumiTimelineCard(
                    key: ValueKey(item.id),
                    bangumiItem: item,
                    compact: compact,
                    showRating: _showRating,
                    isWatching: watchingIds.contains(item.id),
                    isCollected: collectedIds.contains(item.id),
                    airingSlot: _airingSlots[item.id],
                    reserveAiring: hasAiring,
                    onTap: () => context.pushNamed('/info/', arguments: item),
                  );
                },
                childCount: items.length,
              ),
            ),
          ),
      ],
    );
  }
}

class _TimelineScrollView extends StatelessWidget {
  const _TimelineScrollView({super.key, required this.slivers});

  final List<Widget> slivers;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverOverlapInjector(
          handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
        ),
        ...slivers,
      ],
    );
  }
}

class _WeekHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _WeekHeaderDelegate({
    required this.height,
    required this.color,
    required this.child,
  });

  final double height;
  final Color color;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      ColoredBox(color: color, child: child);

  @override
  bool shouldRebuild(covariant _WeekHeaderDelegate oldDelegate) =>
      oldDelegate.height != height ||
      oldDelegate.color != color ||
      oldDelegate.child != child;
}
