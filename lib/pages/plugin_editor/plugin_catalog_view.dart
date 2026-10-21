import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/card/rule_card.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/bean/widget/kazumi_menu.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';
import 'package:kazumi/modules/plugin/rule_repository.dart';
import 'package:kazumi/pages/plugin_editor/plugin_update_actions.dart';
import 'package:kazumi/pages/plugin_editor/rule_management_widgets.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/request/config/rules_repository_config.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/date_time.dart';

enum _CatalogSort { lastUpdate, name }

enum _CatalogFilter { all, installed, updates }

class PluginCatalogView extends StatefulWidget {
  const PluginCatalogView({
    super.key,
    required this.controller,
    this.onManageRepositories,
  }) : _scrollViewBuilder = null;

  const PluginCatalogView.onboarding({
    super.key,
    required this.controller,
    required Widget Function(BuildContext context, List<Widget> slivers)
        builder,
  })  : _scrollViewBuilder = builder,
        onManageRepositories = null;

  final PluginsController controller;

  /// Opens the repository management page. `null` hides every entry point, which
  /// is what the onboarding step wants.
  final VoidCallback? onManageRepositories;

  final Widget Function(BuildContext context, List<Widget> slivers)?
      _scrollViewBuilder;

  bool get _onboarding => _scrollViewBuilder != null;

  @override
  State<PluginCatalogView> createState() => PluginCatalogViewState();
}

class PluginCatalogViewState extends State<PluginCatalogView> {
  final _search = TextEditingController();
  final Set<String> _installing = {};
  _CatalogSort _sort = _CatalogSort.lastUpdate;
  _CatalogFilter _filter = _CatalogFilter.all;
  bool _loading = true;
  bool _loadFailed = false;

  /// Repository totals captured after each load, so the header can show them
  /// without re-reading settings on every frame.
  int _repositoryCount = 0;
  int _enabledRepositoryCount = 0;

  /// Hosts of the repositories that failed. Cleared whenever the user dismisses
  /// the banner; a new failure set brings it back.
  String _dismissedFailures = '';

  PluginsController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _captureRepositoryCounts();
    if (_controller.isPluginCatalogFresh) {
      _loading = false;
    } else {
      unawaited(_loadPluginCatalog());
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadPluginCatalog({bool forceRefresh = false}) async {
    try {
      if (forceRefresh) {
        await _controller.refreshPluginCatalog();
      } else {
        await _controller.ensurePluginCatalog();
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = false;
          _captureRepositoryCounts();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
          _captureRepositoryCounts();
        });
      }
    }
  }

  void _captureRepositoryCounts() {
    final repositories = RulesRepositoryConfig.repositories();
    _repositoryCount = repositories.length;
    _enabledRepositoryCount =
        repositories.where((repository) => repository.enabled).length;
  }

  void _refresh() {
    if (_loading) return;
    _startRefresh();
  }

  /// Reloads the catalog, ignoring the in-flight guard.
  ///
  /// Called after the repository configuration changed. Unlike [_refresh] it
  /// must not be swallowed while the first load is still running, otherwise
  /// switching a repository on/off would leave the list showing the old
  /// catalog.
  void reload() => _startRefresh();

  void _startRefresh() {
    setState(() {
      _loading = true;
      _loadFailed = false;
      _captureRepositoryCounts();
    });
    unawaited(_loadPluginCatalog(forceRefresh: true));
  }

  Future<void> _toggleGitProxyAndRefresh() async {
    try {
      final enabled = GStorage.getSetting(SettingsKeys.enableGitProxy);
      await GStorage.putSetting(SettingsKeys.enableGitProxy, !enabled);
      if (mounted) _refresh();
    } catch (_) {
      KazumiDialog.showToast(message: '切换规则镜像失败，请重试');
    }
  }

  Future<void> _install(
      PluginHTTPItem item, PluginCatalogItemStatus status) async {
    if (!_installing.add(item.name)) return;
    setState(() {});
    try {
      await updatePluginWithFeedback(_controller, item.name,
          installing: status == PluginCatalogItemStatus.install);
    } finally {
      if (mounted) setState(() => _installing.remove(item.name));
    }
  }

  List<PluginHTTPItem> _visibleItems() {
    final query = _search.text.trim().toLowerCase();
    final items = _controller.pluginHTTPList.where((item) {
      final status = _controller.pluginStatus(item);
      return (item.name.toLowerCase().contains(query) ||
              item.author.toLowerCase().contains(query)) &&
          switch (_filter) {
            _CatalogFilter.all => true,
            _CatalogFilter.installed =>
              status != PluginCatalogItemStatus.install,
            _CatalogFilter.updates => status == PluginCatalogItemStatus.update,
          };
    }).toList();
    switch (_sort) {
      case _CatalogSort.lastUpdate:
        items.sort((a, b) => b.lastUpdate.compareTo(a.lastUpdate));
      case _CatalogSort.name:
        items.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return items;
  }

  Widget _sortButton() => KazumiMenuButton(
        builder: (context, toggle) => TextButton.icon(
          onPressed: toggle,
          icon: const Icon(Icons.sort_rounded, size: 20),
          label: Text(_sort == _CatalogSort.name ? '名称排序' : '最近更新'),
        ),
        menuChildren: [
          for (final sort in _CatalogSort.values)
            KazumiMenuItem(
              selected: _sort == sort,
              onPressed: () => setState(() => _sort = sort),
              label: sort == _CatalogSort.name ? '按名称排序' : '按更新时间排序',
            ),
        ],
      );

  Widget _header(int total, int installed, int updates) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!widget._onboarding) ...[
        const RulePageIntro(
          title: '发现更多来源',
          description: '浏览社区规则，为你的番剧搜索添加更多选择。',
          icon: Icons.travel_explore_rounded,
        ),
        if (widget.onManageRepositories != null) ...[
          const SizedBox(height: 12),
          _repositoryEntry(),
        ],
        const SizedBox(height: 20),
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: ruleInputDecoration(context,
              hint: '搜索规则或作者',
              prefix: const Icon(Icons.search_rounded),
              suffix: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      onPressed: () => setState(_search.clear),
                      icon: const Icon(Icons.close_rounded))),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final entry in [
              (_CatalogFilter.all, '全部 $total'),
              (_CatalogFilter.installed, '已安装 $installed'),
              (_CatalogFilter.updates, '可更新 $updates'),
            ])
              FilterChip(
                  label: Text(entry.$2),
                  selected: _filter == entry.$1,
                  onSelected: (_) => setState(() => _filter = entry.$1)),
          ],
        ),
      ],
      Row(children: [
        if (widget._onboarding)
          Expanded(
            child: Text('规则仓库 · 已安装 $installed',
                style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600)),
          )
        else ...[
          _sortButton(),
          const Spacer(),
        ],
        IconButton.filledTonal(
            tooltip: '刷新规则列表',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded)),
      ]),
      if (_loading && total > 0)
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator()),
      if (_loadFailed && total > 0)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('刷新失败，正在显示上次获取的规则。', style: theme.textTheme.bodySmall)),
      const SizedBox(height: 8),
    ]);
  }

  /// Compact entry point into the repository management page.
  ///
  /// Only rendered when the host page wires [PluginCatalogView.onManageRepositories];
  /// the onboarding step passes nothing and stays free of management UI.
  Widget _repositoryEntry() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final summary = _repositoryCount == 0
        ? '暂无规则仓库'
        : '$_repositoryCount 个仓库 · $_enabledRepositoryCount 个已启用';
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onManageRepositories,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            Icon(Icons.lan_rounded, size: 20, color: colors.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(summary,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('规则仓库镜像只作用于官方仓库，第三方仓库不受影响',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }

  /// Yellow banner naming the repositories whose last load failed.
  ///
  /// Partial failures are not errors: the rest of the catalog is perfectly
  /// usable, so this stays dismissible instead of taking over the page.
  Widget? _failureBanner() {
    if (widget._onboarding || _loading || _loadFailed) {
      return null;
    }
    final failures = _controller.repositoryFailures;
    if (failures.isEmpty) {
      return null;
    }
    final labels = failures.map((failure) => failure.repositoryLabel).toList();
    final signature = labels.join('\u0000');
    if (signature == _dismissedFailures) {
      return null;
    }
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Material(
        color: colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(children: [
            Icon(Icons.cloud_off_rounded,
                size: 20, color: colors.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${labels.join('、')} 无法访问，正在显示其他仓库的规则。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colors.onTertiaryContainer),
              ),
            ),
            IconButton(
              tooltip: '忽略',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _dismissedFailures = signature),
              icon: Icon(Icons.close_rounded,
                  size: 18, color: colors.onTertiaryContainer),
            ),
          ]),
        ),
      ),
    );
  }

  /// Where a rule came from, as a single line under the author.
  ///
  /// Repository name wins; otherwise the host of the repository URL; the
  /// built-in repositories are always named rather than spelled out as a host.
  /// `+N` marks rules hidden behind a same-name conflict, and tapping the line
  /// opens them — the source line replaced the chip that used to carry both.
  String _sourceLabel(PluginHTTPItem item) {
    final base = _repositoryName(item);
    final shadowedCount = _controller.shadowedRulesFor(item.name).length;
    return shadowedCount == 0 ? base : '$base +$shadowedCount';
  }

  /// Name of the repository a catalog entry came from.
  String _repositoryName(PluginHTTPItem item) {
    final builtIn = RuleRepositoryList.builtInLabelOf(item.repositoryUrl);
    if (builtIn != null) {
      return builtIn;
    }
    if (item.repositoryLabel.isNotEmpty) {
      return item.repositoryLabel;
    }
    return Uri.tryParse(item.repositoryUrl)?.host ?? '未知来源';
  }

  void _showShadowedSources(PluginHTTPItem item) {
    final shadowed = _controller.shadowedRulesFor(item.name);
    if (shadowed.isEmpty) return;
    KazumiDialog.show<void>(
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text('「${item.name}」的来源'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('同名规则在多个仓库中存在，按仓库顺序使用第一个。',
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              for (final source in [item, ...shadowed])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Icon(
                      source == item
                          ? Icons.check_circle_rounded
                          : Icons.remove_circle_outline_rounded,
                      size: 18,
                      color: source == item
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _repositoryName(source),
                        style: theme.textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(source.version,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ]),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Widget _emptyBody() {
    if (_loading) {
      return const Padding(
          padding: EdgeInsets.all(48),
          child: Center(child: LoadingIndicator()));
    }
    final manageButton = widget.onManageRepositories == null
        ? null
        : StateActionButton.tonal(
            onPressed: widget.onManageRepositories,
            icon: Icons.lan_rounded,
            text: '管理规则仓库',
          );
    if (_enabledRepositoryCount == 0 && _repositoryCount > 0) {
      return GeneralErrorWidget(
        title: '所有规则仓库已关闭',
        errMsg: '打开规则仓库管理，启用至少一个仓库后才能浏览规则。',
        icon: Icons.lan_rounded,
        onRetry: widget.onManageRepositories,
        retryText: '管理规则仓库',
        actions: [
          if (widget.onManageRepositories != null)
            StateActionButton(
              onPressed: reload,
              icon: Icons.refresh_rounded,
              text: '重新加载',
            ),
        ],
      );
    }
    if (_loadFailed && _controller.pluginHTTPList.isEmpty) {
      final failures = _controller.repositoryFailures;
      if (failures.isNotEmpty) {
        return GeneralErrorWidget(
          title: '无法访问任何规则仓库',
          errMsg: '${failures.map((f) => f.repositoryLabel).join('、')} 均无法访问，'
              '请检查网络连接或仓库地址。',
          icon: Icons.cloud_off_rounded,
          onRetry: _refresh,
          retryText: '重新加载',
          actions: [
            ?manageButton,
            if (widget.onManageRepositories == null)
              StateActionButton.tonal(
                onPressed: _toggleGitProxyAndRefresh,
                icon: Icons.tune_rounded,
                text: GStorage.getSetting(SettingsKeys.enableGitProxy)
                    ? '关闭规则镜像'
                    : '启用规则镜像',
              ),
          ],
        );
      }
      final enabled = GStorage.getSetting(SettingsKeys.enableGitProxy);
      return GeneralErrorWidget(
        title: '无法访问规则仓库',
        errMsg: '请检查网络连接，或切换规则仓库镜像后重试。',
        icon: Icons.cloud_off_rounded,
        onRetry: _refresh,
        retryText: '重新加载',
        actions: [
          ?manageButton,
          if (widget.onManageRepositories == null)
            StateActionButton.tonal(
              onPressed: _toggleGitProxyAndRefresh,
              icon: Icons.tune_rounded,
              text: enabled ? '关闭规则镜像' : '启用规则镜像',
            ),
        ],
      );
    }
    return GeneralEmptyState(
      title: _controller.pluginHTTPList.isEmpty ? '仓库暂无规则' : '没有符合条件的规则',
      icon: _controller.pluginHTTPList.isEmpty
          ? Icons.extension_rounded
          : Icons.search_off_rounded,
    );
  }

  @override
  Widget build(BuildContext context) => Observer(builder: (context) {
        final colors = Theme.of(context).colorScheme;
        final catalog = _controller.pluginHTTPList.toList();
        final installed = catalog
            .where((p) =>
                _controller.pluginStatus(p) != PluginCatalogItemStatus.install)
            .length;
        final updates = catalog
            .where((p) =>
                _controller.pluginStatus(p) == PluginCatalogItemStatus.update)
            .length;
        final items = _visibleItems();
        final slivers = <Widget>[
          SliverPadding(
            padding: widget._onboarding
                ? EdgeInsets.zero
                : const EdgeInsets.fromLTRB(16, 12, 16, 24),
            sliver: SliverMainAxisGroup(slivers: [
              SliverToBoxAdapter(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(catalog.length, installed, updates),
                  ?_failureBanner(),
                ],
              )),
              if (items.isEmpty)
                SliverToBoxAdapter(child: _emptyBody())
              else
                SliverList.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final status = _controller.pluginStatus(item);
                    final busy = _installing.contains(item.name);
                    // The address line shows the rule's own baseURL, which the
                    // catalog file does not carry; it resolves asynchronously
                    // and the line simply stays hidden until then.
                    return FutureBuilder<String?>(
                      future: _controller.ruleBaseUrl(item),
                      builder: (context, snapshot) => RuleCard(
                      key: ValueKey(item.name),
                      title: item.name,
                      titleTag: RuleTag(
                          label: item.version,
                          width: 44,
                          height: 16,
                          radius: 6,
                          fontSize: 10,
                          // 版本号固定绿色，不跟主题走：它是「版本」这个身份的
                          // 固定记号，换了主题也该一眼认出来。
                          background: const Color(0xFFCDEFD4),
                          foreground: const Color(0xFF1B5E33)),
                      // 源类型跟作者同一行：它描述规则的实现方式，
                      // 不是身份信息，不该挤在名称旁边。
                      subtitleTag: item.type.isEmpty
                          ? null
                          : RuleTag(
                              label: item.type,
                              width: 44,
                              // 16 = bodySmall 的行高，再高就会把作者行撑开。
                              height: 16,
                              radius: 6,
                              fontSize: 10,
                              background: colors.secondaryContainer,
                              foreground: colors.onSecondaryContainer),
                      installed: status == PluginCatalogItemStatus.installed,
                      subtitle:
                          item.author.isEmpty ? null : '作者 · ${item.author}',
                      source: item.repositoryUrl.isEmpty
                          ? null
                          : _sourceLabel(item),
                      onSourceTap:
                          _controller.shadowedRulesFor(item.name).isEmpty
                              ? null
                              : () => _showShadowedSources(item),
                      webUrl: snapshot.data,
                      caption: item.lastUpdate > 0
                          ? '更新 · ${formatDateTimeWithSeconds(DateTime.fromMillisecondsSinceEpoch(item.lastUpdate))}'
                          : null,
                        trailing: _CatalogRuleAction(
                          status: status,
                          busy: busy,
                          onPressed: () => _install(item, status),
                        ),
                      ),
                    );
                  },
                ),
            ]),
          ),
        ];
        return widget._scrollViewBuilder?.call(context, slivers) ??
            CustomScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: slivers,
            );
      });
}

class _CatalogRuleAction extends StatelessWidget {
  const _CatalogRuleAction({
    required this.status,
    required this.busy,
    required this.onPressed,
  });

  final PluginCatalogItemStatus status;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (!busy && status == PluginCatalogItemStatus.installed) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_rounded, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 6),
          Text('已安装',
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: colors.onSurfaceVariant)),
        ]),
      );
    }
    final installing = status == PluginCatalogItemStatus.install;
    return FilledButton.tonal(
      style: FilledButton.styleFrom(
        minimumSize: const Size(108, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      onPressed: busy ? null : onPressed,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (busy)
          const LoadingIndicator(size: 20)
        else
          Icon(installing ? Icons.add_rounded : Icons.sync_rounded, size: 18),
        const SizedBox(width: 6),
        Text(installing ? (busy ? '安装中' : '安装') : (busy ? '更新中' : '更新')),
      ]),
    );
  }
}
