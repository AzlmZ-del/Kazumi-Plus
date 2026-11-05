part of 'timeline_page.dart';

class _TimelineWeekSelector extends StatelessWidget {
  const _TimelineWeekSelector({
    required this.counts,
    this.todayIndex,
    this.isLoading = false,
  });

  final List<int> counts;
  final int? todayIndex;
  final bool isLoading;

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  /// 星期栏的总高度。
  ///
  /// 由「上下留白 24 + 主文字行高 + 数量行高」三段组成（scale 1.0 时 54 dp），
  /// 留白从 32 压到 24，胶囊更扁。
  static double heightFor(TextScaler scaler) =>
      24 + scaler.scale(18) + scaler.scale(12);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      // 每个 tab 的最小可用宽度：字号×2 + 左右内边距。原来的 16 太宽，
      // 窄屏下 7 个 tab 挤不下就切成可滚动，导致「周日」被挤出屏幕。
      // 这里压到 8，让 7 个 tab 在常见手机宽度下都能完整显示。
      final minTabWidth = (scaler.scale(14) * 2 + 8).clamp(40.0, 112.0);
      final scrollable = constraints.maxWidth - 8 < minTabWidth * 7;
      return DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: TabBar(
            isScrollable: scrollable,
            tabAlignment: scrollable ? TabAlignment.start : TabAlignment.fill,
            dividerHeight: 0,
            indicatorSize: TabBarIndicatorSize.tab,
            indicator: BoxDecoration(
              color: colors.primary,
              borderRadius: BorderRadius.circular(24),
            ),
            indicatorAnimation: TabIndicatorAnimation.elastic,
            labelColor: colors.onPrimary,
            unselectedLabelColor: colors.onSurfaceVariant,
            // 标签内边距从 4 收到 2，进一步给 7 个 tab 腾出横向空间。
            labelPadding: const EdgeInsets.symmetric(horizontal: 2),
            labelStyle: theme.textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.w700),
            overlayColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.hovered) ||
                        states.contains(WidgetState.focused)
                    ? colors.primary.withValues(alpha: .08)
                    : null),
            splashBorderRadius: BorderRadius.circular(24),
            tabs: [
              for (var day = 0; day < 7; day++)
                Tab(
                  height: heightFor(scaler) - 8,
                  child: Semantics(
                    label: '星期${_weekdays[day]}'
                        '${day == todayIndex ? '，今天' : ''}'
                        '${isLoading ? '，加载中' : '，${counts[day]}部'}',
                    excludeSemantics: true,
                    child: SizedBox(
                      width: scrollable ? minTabWidth : null,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            day == todayIndex ? '今天' : '周${_weekdays[day]}',
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(fontSize: scaler.scale(14)),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isLoading ? '—' : '${counts[day]}',
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: theme.textTheme.labelSmall?.fontSize,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}
