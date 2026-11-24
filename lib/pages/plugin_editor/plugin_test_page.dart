import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/plugin_editor/rule_management_widgets.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/pages/webview/internal_browser_page.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/speed_tier.dart';
import 'package:url_launcher/url_launcher.dart';

const _h8 = SizedBox(height: 8.0);
const _h12 = SizedBox(height: 12.0);

/// Link text in result cards is always green, not the theme color (specified by the user on 2026-10-22).
///
/// Reuses the fast-tier speed color so the two hardcoded values cannot drift apart.
const _linkGreen = kSpeedTierFastColor;

class PluginTestPage extends StatefulWidget {
  const PluginTestPage({
    super.key,
    required this.plugin,
  });

  final Plugin plugin;

  @override
  State<PluginTestPage> createState() => _PluginTestPageState();
}

class _PluginTestPageState extends State<PluginTestPage>
    with KazumiDialogOwner {
  late final Plugin plugin;
  final testKeywordController = TextEditingController();
  final searchRawScrollController = ScrollController();
  final chapterRawScrollController = ScrollController();
  final fragmentScrollController = ScrollController();

  String searchRaw = "";
  String chapterRaw = "";
  PluginSearchResponse? searchRes;
  List<Road>? chapters;
  bool isTesting = false;
  bool _hasRun = false;
  int _runId = 0;
  int? _searchElapsedMs;
  int? _chapterElapsedMs;
  String errorMsg = "";
  List<String> searchDiagnostics = [];
  List<String> chapterDiagnostics = [];
  final Map<int, String> _itemFragmentMap = {};
  int? _shownFragmentIndex;

  /// Index of the search result whose playback roads are being viewed (0-based).
  int _selectedItemIndex = 0;

  /// Chapter request sequence number; responses superseded by a later tap are discarded.
  int _chapterRunId = 0;

  /// Whether a chapter request is in flight (used while tapping another result).
  bool _chapterLoading = false;

  bool get _hasSearchRaw => searchRaw.isNotEmpty;

  bool get _hasSearchData => searchRes?.data.isNotEmpty ?? false;

  bool get _hasChapters => chapters?.isNotEmpty ?? false;

  bool get _needChapterParse =>
      plugin.chapterMode == RuleMode.api || plugin.chapterRoads.isNotEmpty;

  CancelToken? _testCancelToken;

  @override
  void initState() {
    super.initState();
    plugin = widget.plugin;
    testKeywordController.addListener(
        () => errorMsg.isNotEmpty ? setState(() => errorMsg = "") : null);
  }

  @override
  void dispose() {
    _testCancelToken?.cancel();
    testKeywordController.dispose();
    searchRawScrollController.dispose();
    chapterRawScrollController.dispose();
    fragmentScrollController.dispose();
    super.dispose();
  }

  void _resetState() => setState(() {
        _runId++;
        isTesting = false;
        _hasRun = false;
        _testCancelToken?.cancel();
        _testCancelToken = null;
        searchRaw = "";
        chapterRaw = "";
        searchRes = null;
        chapters = null;
        errorMsg = "";
        _searchElapsedMs = null;
        _chapterElapsedMs = null;
        searchDiagnostics = [];
        chapterDiagnostics = [];
        _itemFragmentMap.clear();
        _shownFragmentIndex = null;
        _selectedItemIndex = 0;
        _chapterRunId++;
        _chapterLoading = false;
      });

  void _toggleFragment(int index) => setState(
      () => _shownFragmentIndex = _shownFragmentIndex == index ? null : index);

  Future<void> _startTest() async {
    if (isTesting) return;
    final keyword = testKeywordController.text.trim();
    if (keyword.isEmpty) {
      setState(() => errorMsg = '请输入一个番剧名称作为测试关键词。');
      return;
    }
    _resetState();
    // Ignore late responses when cancellation is not honored.
    final runId = _runId;
    final cancelToken = _testCancelToken = CancelToken();
    setState(() {
      isTesting = true;
      _hasRun = true;
    });
    final stopwatch = Stopwatch()..start();
    try {
      final searchTrace =
          await plugin.traceSearch(keyword, cancelToken: cancelToken);
      if (!mounted || runId != _runId) return;
      setState(() {
        _searchElapsedMs = stopwatch.elapsedMilliseconds;
        searchRaw = searchTrace.rawResponse;
        searchRes = searchTrace.response;
        searchDiagnostics = searchTrace.diagnostics;
        _itemFragmentMap.addAll(searchTrace.matchedFragments.asMap());
      });
      if (_hasSearchData && _needChapterParse) {
        // Defaults to the first one; tapping another result card re-fetches its playback roads.
        await _selectItem(0, cancelToken: cancelToken, throwOnError: true);
      }
    } catch (error, stack) {
      if (!mounted || runId != _runId) return;
      KazumiLogger()
          .e('PluginTest: test failed', error: error, stackTrace: stack);
      setState(() {
        _searchElapsedMs ??= stopwatch.elapsedMilliseconds;
        errorMsg = error.toString();
      });
    } finally {
      if (mounted && runId == _runId) setState(() => isTesting = false);
    }
  }

  /// Selects search result [index] and fetches its own playback roads.
  ///
  /// With [throwOnError] true the exception is rethrown to the caller (first test run, shown
  /// in the top error card); tapping a card passes false so errors only clear stale data.
  Future<void> _selectItem(
    int index, {
    CancelToken? cancelToken,
    bool throwOnError = false,
  }) async {
    final data = searchRes?.data;
    if (data == null || index < 0 || index >= data.length) return;
    final item = data[index];
    final chapterRunId = ++_chapterRunId;
    setState(() {
      _selectedItemIndex = index;
      chapterRaw = "";
      chapters = null;
      chapterDiagnostics = [];
      _chapterElapsedMs = null;
      _chapterLoading = item.src.isNotEmpty;
    });
    if (item.src.isEmpty) return;
    final stopwatch = Stopwatch()..start();
    try {
      final chapterTrace =
          await plugin.traceChapters(item.src, cancelToken: cancelToken);
      if (!mounted || chapterRunId != _chapterRunId) return;
      setState(() {
        _chapterElapsedMs = stopwatch.elapsedMilliseconds;
        chapterRaw = chapterTrace.rawResponse;
        chapters = chapterTrace.roads;
        chapterDiagnostics = chapterTrace.diagnostics;
        _chapterLoading = false;
      });
    } catch (error, stack) {
      if (!mounted || chapterRunId != _chapterRunId) return;
      setState(() {
        _chapterElapsedMs = stopwatch.elapsedMilliseconds;
        _chapterLoading = false;
      });
      if (throwOnError) rethrow;
      KazumiLogger().e('PluginTest: chapter fetch failed',
          error: error, stackTrace: stack);
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '获取播放线路失败');
      }
    }
  }

  /// Tapping a result card: selects that result and re-fetches its playback roads.
  Future<void> _onItemTap(int index) async {
    if (isTesting) return;
    // Already selected and data still present: skip the duplicate request.
    if (index == _selectedItemIndex && chapters != null) return;
    await _selectItem(index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsDetailScaffold(
      title: const Text('规则测试'),
      actions: [
        IconButton(
          onPressed: _resetState,
          icon: const Icon(Icons.restart_alt_rounded),
          tooltip: '重置测试',
        ),
        const SizedBox(width: 8),
      ],
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  RulePageIntro(
                    title: plugin.name,
                    description: RuleModeText.summary(
                      host: Uri.tryParse(plugin.baseUrl)?.host,
                      searchMode: plugin.searchMode,
                      chapterMode: plugin.chapterMode,
                    ),
                    icon: Icons.science_outlined,
                  ),
                  const SizedBox(height: 20),
                  RuleSection(
                    title: '试着搜索一部番剧',
                    description: '点击「番剧条目」里的任意一条，即可查看它的播放线路。',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildKeywordInput(),
                        const SizedBox(height: 16),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                                minimumSize: const Size(132, 48)),
                            onPressed: isTesting ? _resetState : _startTest,
                            icon: Icon(isTesting
                                ? Icons.stop_rounded
                                : Icons.play_arrow_rounded),
                            label: Text(isTesting ? '停止测试' : '开始测试'),
                          ),
                        ),
                        if (isTesting) ...[
                          const SizedBox(height: 16),
                          const LinearProgressIndicator(),
                        ],
                      ],
                    ),
                  ),
                  if (errorMsg.isNotEmpty && !isTesting) ...[
                    const SizedBox(height: 16),
                    _buildErrorWidget(theme),
                  ],
                  const SizedBox(height: 20),
                  _buildExpansionTile(
                      theme: theme,
                      number: 1,
                      title: '搜索请求',
                      subtitleWidget: _buildSubtitleWithElapsed(
                          _getSearchSubtitle(), _searchElapsedMs, theme),
                      completed: _hasSearchRaw,
                      expanded: false,
                      child: _buildSearchContent(theme)),
                  _h12,
                  _buildExpansionTile(
                      theme: theme,
                      number: 2,
                      title: '番剧条目',
                      subtitle: _getParseSubtitle(),
                      completed: _hasSearchData,
                      expanded: false,
                      child: _buildParseContent(theme)),
                  _h12,
                  _buildExpansionTile(
                      theme: theme,
                      number: 3,
                      title: _getResponseTitle(),
                      subtitleWidget: _buildChapterRawSubtitle(theme),
                      completed: _needChapterParse && chapterRaw.isNotEmpty,
                      expanded: false,
                      child: _buildChapterRawContent(theme)),
                  _h12,
                  if (_hasChapters)
                    // One card per road, laid out at the same level as the search request.
                    ...chapters!.asMap().entries.expand((e) {
                      final i = e.key;
                      final road = e.value;
                      final roadName = road.name.trim();
                      return [
                        _buildExpansionTile(
                            theme: theme,
                            number: 4 + i,
                            title: '播放线路 ${i + 1}',
                            completed: true,
                            expanded: false,
                            failedOverride: false,
                            subtitleWidget: _buildSubtitleWithElapsed(
                                roadName.isEmpty
                                    ? '章节数量：${road.data.length}'
                                    : '$roadName · 章节数量：${road.data.length}',
                                null,
                                theme),
                            child: _buildRoadChapterList(road, theme)),
                        _h12,
                      ];
                    })
                  else if (_needChapterParse &&
                      _hasSearchData &&
                      !isTesting &&
                      !_chapterLoading)
                    _buildExpansionTile(
                        theme: theme,
                        number: 4,
                        title: '播放线路',
                        subtitle: _getChapterSubtitle(),
                        completed: false,
                        expanded: false,
                        child: _buildEmpty('无可用章节', theme, isError: true)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExpansionTile({
    required ThemeData theme,
    required int number,
    required String title,
    String subtitle = '',
    required bool completed,
    required bool expanded,
    required Widget child,
    bool? failedOverride,
    Widget? subtitleWidget,
  }) {
    final colors = theme.colorScheme;
    final failed = failedOverride ??
        (_hasRun &&
            !isTesting &&
            !completed &&
            switch (number) {
              1 => true,
              2 => _hasSearchRaw,
              3 => _hasSearchData && _needChapterParse && !_chapterLoading,
              _ => _hasSearchData && _needChapterParse && !_chapterLoading,
            });
    final foreground = completed
        ? colors.onTertiaryContainer
        : failed
            ? colors.onErrorContainer
            : colors.onSurfaceVariant;
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: ValueKey('$number-$_hasRun-$completed'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
              color: completed
                  ? colors.tertiaryContainer
                  : failed
                      ? colors.errorContainer
                      : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(completed ? 20 : 12)),
          child: Center(
              child: completed
                  ? Icon(Icons.check_rounded, color: foreground)
                  : failed
                      ? Icon(Icons.error_outline_rounded, color: foreground)
                      : Text('$number',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(color: foreground))),
        ),
        title: Text(title,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: subtitleWidget ??
            Text(subtitle,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant)),
        initiallyExpanded: expanded,
        shape: const Border(),
        collapsedShape: const Border(),
        children: [child],
      ),
    );
  }

  Widget _buildKeywordInput() => TextField(
        controller: testKeywordController,
        decoration: ruleInputDecoration(context,
            label: '测试关键词',
            hint: '输入番剧名称',
            prefix: const Icon(Icons.search_rounded)),
        enabled: !isTesting,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _startTest(),
      );

  Widget _buildErrorWidget(ThemeData theme) => Container(
        padding: const EdgeInsets.all(12.0),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.error_outline, color: theme.colorScheme.error, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(errorMsg,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onErrorContainer)),
              _h8,
              TextButton(
                onPressed: _startTest,
                style: TextButton.styleFrom(
                    backgroundColor:
                        theme.colorScheme.error.withValues(alpha: 0.1)),
                child: Text('重试测试',
                    style:
                        TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            ]),
          ),
        ]),
      );

  Widget _buildLoading(ThemeData theme) => Center(
        child: LoadingIndicator(
          color: theme.colorScheme.primary,
        ),
      );

  Widget _buildEmpty(String text, ThemeData theme, {bool isError = false}) =>
      Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: isError
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );

  String _getSearchSubtitle() {
    if (isTesting && !_hasSearchRaw) return '正在请求站点…';
    if (!_hasSearchRaw) return _hasRun ? '没有收到响应' : '等待开始';
    return '${plugin.searchMode == RuleMode.api ? 'JSON' : 'HTML'}长度：${searchRaw.length} 字符';
  }

  /// Request latency tiers: < 500ms green, 500-1000ms orange, >= 1000ms red;
  /// falls back to the subtitle default color when no latency is recorded (not started / failed / cancelled).
  Color _elapsedColor(int? ms, Color fallback) =>
      speedTierColor(speedTierOf(ms), fallback);

  /// Subtitle plus a second line showing the elapsed time as `xxxx ms`.
  ///
  /// The latency row keeps the subtitle bodySmall size and weight, only the color switches to the tier color;
  /// when [ms] is null (not started / failed / cancelled) no row is reserved and a single line is returned.
  Widget _buildSubtitleWithElapsed(
    String text,
    int? ms,
    ThemeData theme,
  ) {
    final baseStyle = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    if (ms == null) return Text(text, style: baseStyle);
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: '$text\n'),
        TextSpan(
          text: '返回时间：$ms ms',
          style: TextStyle(
            color: _elapsedColor(ms, theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ]),
      style: baseStyle,
    );
  }

  /// Bottom row of a result card: item ID in API mode, a tap-to-copy link in XPath mode.
  Widget _buildSrcLine(SearchItem item, bool selected, ThemeData theme) {
    if (plugin.searchMode == RuleMode.api) {
      return Text(
        'ID：${item.src}',
        style: theme.textTheme.bodySmall?.copyWith(
            color: selected
                ? theme.colorScheme.onPrimaryContainer
                : theme.colorScheme.onSurfaceVariant),
      );
    }
    return InkWell(
      onTap: isTesting ? null : () => _copyUrl(item.src),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          item.src,
          style: theme.textTheme.bodySmall?.copyWith(color: _linkGreen),
        ),
      ),
    );
  }

  /// Two icon buttons at the right of a result card title: in-app browse and open externally (only XPath mode has a link).
  Widget _buildSrcActions(SearchItem item, ThemeData theme) {
    if (plugin.searchMode == RuleMode.api) {
      return const SizedBox.shrink();
    }
    final colors = theme.colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _episodeActionButton(
          tooltip: '内部浏览',
          icon: Icons.travel_explore_rounded,
          onPressed: isTesting ? null : () => _openUrlInternal(item.src, item.name),
          background: colors.secondaryContainer,
          foreground: colors.onSecondaryContainer,
        ),
        const SizedBox(width: 4),
        _episodeActionButton(
          tooltip: '外部打开',
          icon: Icons.open_in_new,
          onPressed: isTesting ? null : () => _openUrlExternal(item.src),
          background: colors.secondaryContainer,
          foreground: colors.onSecondaryContainer,
        ),
      ],
    );
  }

  /// Opens a page in the in-app browser, honoring the source UA and direct-connection setting.
  void _openUrlInternal(String url, String title) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => InternalBrowserPage(
          url: url,
          title: title,
          userAgent: plugin.userAgent,
          directConnection: plugin.directConnection,
        ),
      ),
    );
  }

  /// Hands the link to the system browser.
  Future<void> _openUrlExternal(String url) async {
    try {
      if (await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (error) {
      KazumiLogger().w('PluginTestPage: failed to open url', error: error);
    }
    if (mounted) {
      KazumiDialog.showToast(context: context, message: '无法打开浏览器');
    }
  }

  Widget _codePanel(String raw, ThemeData theme,
      {ScrollController? controller}) {
    return Container(
      decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4, top: 4),
            child: Row(children: [
              Expanded(child: Text('响应内容', style: theme.textTheme.labelLarge)),
              IconButton(
                  tooltip: '复制响应内容',
                  onPressed: () async {
                    try {
                      await Clipboard.setData(ClipboardData(text: raw));
                      if (mounted) {
                        KazumiDialog.showToast(
                            context: context, message: '已复制响应内容');
                      }
                    } catch (_) {
                      if (mounted) {
                        KazumiDialog.showToast(
                            context: context, message: '复制失败，请重试');
                      }
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18)),
            ]),
          ),
          SizedBox(
            height: 220,
            child: Scrollbar(
              controller: controller,
              child: SingleChildScrollView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: SelectableText(raw,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontFamily: 'monospace')),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchContent(ThemeData theme) {
    if (isTesting && !_hasSearchRaw) return _buildLoading(theme);
    if (!_hasSearchRaw) return _buildEmpty('输入关键词后，点击「开始测试」。', theme);
    return _codePanel(
        _formattedRaw(searchRaw), theme,
        controller: searchRawScrollController);
  }

  String _getParseSubtitle() {
    if (isTesting && !_hasSearchRaw) return '等待搜索响应';
    if (!_hasSearchRaw) return _hasRun ? '等待有效响应' : '等待开始';
    if (!_hasSearchData) return '未解析到结果';
    final skipped =
        searchDiagnostics.isEmpty ? '' : '，跳过 ${searchDiagnostics.length} 条';
    return '解析到 ${searchRes?.data.length ?? 0} 条结果$skipped';
  }

  Widget _buildParseContent(ThemeData theme) {
    if (isTesting && !_hasSearchRaw) return _buildLoading(theme);
    if (!_hasSearchRaw) return _buildEmpty('请先完成搜索请求测试', theme);
    if (!_hasSearchData) return _buildEmpty('未解析到搜索结果', theme, isError: true);

    return Column(children: [
      _buildDiagnosticsWidget(searchDiagnostics, theme),
      ListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: searchRes!.data.length,
        itemBuilder: (_, i) =>
            _buildSearchItemCard(searchRes!.data[i], i, theme),
      ),
      _h8,
    ]);
  }

  Widget _buildDiagnosticsWidget(List<String> diagnostics, ThemeData theme) {
    if (diagnostics.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8.0),
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.warning_amber_outlined,
                color: theme.colorScheme.error, size: 20),
            const SizedBox(width: 8.0),
            Expanded(
                child: Text('部分节点被跳过（${diagnostics.length}）',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                        fontWeight: FontWeight.w500))),
          ]),
          _h8,
          ...diagnostics.map(
            (message) => Padding(
              padding: const EdgeInsets.only(bottom: 4.0),
              child: SelectableText(message,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onErrorContainer)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchItemCard(SearchItem item, int i, ThemeData theme) {
    final isShowingFragment = _shownFragmentIndex == i;
    final fragment = _itemFragmentMap[i] ?? '无匹配片段';
    // Highlights the result whose playback roads are being viewed with a tinted background and border.
    final selected = _selectedItemIndex == i;

    return Column(children: [
      Card(
        margin: const EdgeInsets.only(bottom: 8.0),
        elevation: 0,
        color: selected
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: selected
              ? BorderSide(color: theme.colorScheme.primary, width: 1.5)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: isTesting ? null : () => _onItemTap(i),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            '${i + 1}：${item.name}',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w500),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _buildSrcActions(item, theme),
                        IconButton(
                          onPressed:
                              isTesting ? null : () => _toggleFragment(i),
                          icon: Icon(
                            isShowingFragment
                                ? Icons.keyboard_arrow_up
                                : Icons.code,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                          iconSize: 18,
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints.tightFor(
                            width: 32,
                            height: 32,
                          ),
                          tooltip:
                              isShowingFragment ? '隐藏匹配片段' : '查看匹配片段',
                        ),
                      ]),
                  _h8,
                  _buildSrcLine(item, selected, theme),
                ]),
          ),
        ),
      ),
      if (isShowingFragment)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _codePanel(_formattedRaw(fragment), theme,
              controller: fragmentScrollController),
        ),
    ]);
  }

  String _getChapterSubtitle() {
    if (!_hasRun) return '等待开始';
    if (isTesting) return _hasSearchData ? '正在获取播放线路…' : '等待搜索结果';
    if (!_hasSearchData) return '等待有效搜索结果';
    if (!_needChapterParse) return '无需解析章节';
    if (_chapterLoading) return '正在获取第 ${_selectedItemIndex + 1} 条的播放线路…';
    if (chapters == null) return '第 ${_selectedItemIndex + 1} 条 · 未获取章节数据';
    final skipped =
        chapterDiagnostics.isEmpty ? '' : '，跳过 ${chapterDiagnostics.length} 条';
    return '第 ${_selectedItemIndex + 1} 条 · 获取到 ${chapters?.length ?? 0} 个播放线路$skipped';
  }

  /// Card title shows the name picked in the anime-entry list, falling back to the default label.
  String _getResponseTitle() {
    final data = searchRes?.data;
    if (data == null || data.isEmpty) return '响应内容';
    final index = _selectedItemIndex;
    if (index < 0 || index >= data.length) return '响应内容';
    final name = data[index].name.trim();
    return name.isEmpty ? '响应内容' : name;
  }

  /// Subtitle of the "response content" card: data type and length (the title already shows the anime name, so the item index is omitted).
  Widget _buildChapterRawSubtitle(ThemeData theme) {
    final kind = plugin.chapterMode == RuleMode.api ? 'JSON' : 'HTML';
    final String text;
    if (!_hasRun) {
      text = '等待开始';
    } else if (isTesting) {
      text = _hasSearchData ? '正在获取响应…' : '等待搜索结果';
    } else if (!_hasSearchData) {
      text = '等待有效搜索结果';
    } else if (!_needChapterParse) {
      text = '无需解析章节';
    } else if (_chapterLoading) {
      text = '正在获取响应…';
    } else if (chapterRaw.isEmpty) {
      text = '未获取到响应';
    } else {
      text = '$kind长度：${chapterRaw.length} 字符';
    }
    return _buildSubtitleWithElapsed(text, _chapterElapsedMs, theme);
  }

  Widget _buildChapterRawContent(ThemeData theme) {
    if (!_needChapterParse) return _buildEmpty('未填写章节规则', theme);
    if (isTesting || _chapterLoading) return _buildLoading(theme);
    if (!_hasSearchData) return _buildEmpty('请先解析到有效结果', theme);
    if (chapterRaw.isEmpty) {
      return _buildEmpty('未获取到响应内容', theme, isError: true);
    }

    return Column(
      children: [
        _buildDiagnosticsWidget(chapterDiagnostics, theme),
        _codePanel(_formattedRaw(chapterRaw), theme,
            controller: chapterRawScrollController),
      ],
    );
  }

  /// Chapter details for a single road: one small card per episode, with three icon buttons
  /// (in-app browse / open externally / test playback) at the right of the title row; long-press shows a tooltip.
  Widget _buildRoadChapterList(Road road, ThemeData theme) {
    if (road.identifier.isEmpty) {
      return _buildEmpty('这条线路没有章节', theme);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < road.identifier.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _buildEpisodeCard(road, i, theme),
          ),
      ],
    );
  }

  Widget _buildEpisodeCard(Road road, int index, ThemeData theme) {
    final colors = theme.colorScheme;
    final name = road.identifier[index];
    final url = index < road.data.length ? road.data[index] : '';
    return Material(
      color: colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 8, top: 6, bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500),
                  ),
                ),
                const SizedBox(width: 4),
                _episodeActionButton(
                  tooltip: '内部浏览',
                  icon: Icons.travel_explore_rounded,
                  onPressed:
                      url.isEmpty ? null : () => _openEpisodeInternal(road, index),
                  background: colors.secondaryContainer,
                  foreground: colors.onSecondaryContainer,
                ),
                const SizedBox(width: 4),
                _episodeActionButton(
                  tooltip: '外部打开',
                  icon: Icons.open_in_new,
                  onPressed:
                      url.isEmpty ? null : () => _openEpisodeExternal(road, index),
                  background: colors.secondaryContainer,
                  foreground: colors.onSecondaryContainer,
                ),
                const SizedBox(width: 4),
                _episodeActionButton(
                  tooltip: '测试播放',
                  icon: Icons.play_circle_outline,
                  onPressed:
                      url.isEmpty ? null : () => _startTestPlayback(road, index),
                  background: colors.primaryContainer,
                  foreground: colors.onPrimaryContainer,
                ),
              ],
            ),
            if (url.isNotEmpty) ...[
              const SizedBox(height: 4),
              InkWell(
                onTap: () => _copyUrl(url),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    url,
                    style:
                        theme.textTheme.bodySmall?.copyWith(color: _linkGreen),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Icon buttons in the top-right corner of an episode card; all three share size and corner radius.
  Widget _episodeActionButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    required Color background,
    required Color foreground,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
      iconSize: 18,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      style: IconButton.styleFrom(
        foregroundColor: foreground,
        backgroundColor: background,
        disabledBackgroundColor: background.withValues(alpha: 0.4),
      ),
    );
  }

  /// Copies a text (episode link, result link) to the clipboard.
  Future<void> _copyUrl(String url) async {
    try {
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '链接已复制');
      }
    } catch (error) {
      KazumiLogger().w('PluginTestPage: failed to copy url', error: error);
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '复制失败，请重试');
      }
    }
  }

  /// Opens the episode link in the in-app browser.
  void _openEpisodeInternal(Road road, int index) {
    _openUrlInternal(road.data[index], road.identifier[index]);
  }

  /// Opens the episode link in the system browser.
  Future<void> _openEpisodeExternal(Road road, int index) async {
    await _openUrlExternal(road.data[index]);
  }

  /// Test playback: jumps into the player with the already-resolved road, positioned at the tapped episode.
  ///
  /// Danmaku and discussion need a Bangumi subject id, so the anime name is searched on Bangumi
  /// and the first real hit is passed in; without one a synthetic entry is used (no danmaku/discussion).
  Future<void> _startTestPlayback(Road road, int index) async {
    final data = searchRes?.data;
    if (data == null || data.isEmpty) {
      KazumiDialog.showToast(context: context, message: '请先解析出搜索结果');
      return;
    }
    final itemIndex = _selectedItemIndex;
    if (itemIndex < 0 || itemIndex >= data.length) {
      KazumiDialog.showToast(context: context, message: '请先选择一条搜索结果');
      return;
    }
    final roads = chapters;
    if (roads == null || roads.isEmpty) {
      KazumiDialog.showToast(context: context, message: '请先解析播放线路');
      return;
    }
    final roadIndex = roads.indexOf(road);
    final item = data[itemIndex];
    final rawName = item.name.trim().isEmpty ? plugin.name : item.name.trim();

    BangumiItem? matched;
    await dialogs.run((task) async {
      matched = await task.loading<BangumiItem?>(
        title: '测试播放',
        message: '正在关联 Bangumi 条目…',
        action: () async {
          try {
            final page = await BangumiApi.bangumiSearch(rawName, limit: 10);
            final items = page?.items ?? const <BangumiItem>[];
            return items.isEmpty ? null : items.first;
          } catch (error) {
            KazumiLogger()
                .w('PluginTestPage: bangumi search failed', error: error);
            return null;
          }
        },
      );
    });
    if (!mounted) return;

    final matchedItem = matched;
    final bangumiItem = matchedItem ??
        BangumiItem(
          id: 0,
          type: 2,
          name: rawName,
          nameCn: rawName,
          summary: '',
          airDate: '',
          airWeekday: 0,
          rank: 0,
          images: const {},
          tags: const [],
          alias: const [],
          ratingScore: 0,
          votes: 0,
          votesCount: const [],
          info: '',
        );
    if (matchedItem == null) {
      KazumiDialog.showToast(
        context: context,
        message: '没匹配到 Bangumi 条目，弹幕与讨论不可用',
      );
    }
    final title = matchedItem == null
        ? rawName
        : (matchedItem.nameCn.isNotEmpty
            ? matchedItem.nameCn
            : matchedItem.name);    context.pushNamed(
      '/video/',
      arguments: OnlineVideoPlaybackArgs(
        bangumiItem: bangumiItem,
        plugin: plugin,
        title: title,
        src: item.src,
        roads: roads,
        initialEpisode: index + 1,
        initialRoad: roadIndex < 0 ? 0 : roadIndex,
        pinInitialEpisode: true,
      ),
    );
  }

  /// Expands JSON in the response into indented multi-line text; HTML is returned as-is.
  ///
  /// Decided by content rather than search/chapter mode: only a first character of `{` or `[`
  /// triggers parsing, so HTML responses (starting with `<`) are never mangled.
  String _formattedRaw(String raw) {
    final trimmed = raw.trimLeft();
    if (trimmed.isEmpty) return raw;
    final head = trimmed.codeUnitAt(0);
    if (head != 0x7B && head != 0x5B) return raw; // '{' or '['
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } catch (_) {
      return raw;
    }
  }
}
