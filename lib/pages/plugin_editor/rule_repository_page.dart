import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/widget/kazumi_menu.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';
import 'package:kazumi/modules/plugin/rule_repository.dart';
import 'package:kazumi/pages/plugin_editor/rule_management_widgets.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/request/config/rules_repository_config.dart';

/// Manages the list of rule repositories: order, on/off, rename, edit, delete.
///
/// Order *is* priority: the first enabled repository to advertise a rule name
/// wins, which is why dragging exists at all.
class RuleRepositoryPage extends StatefulWidget {
  const RuleRepositoryPage({super.key, required this.controller});

  final PluginsController controller;

  @override
  State<RuleRepositoryPage> createState() => _RuleRepositoryPageState();
}

class _RuleRepositoryPageState extends State<RuleRepositoryPage> {
  List<RuleRepository> _repositories = const [];
  bool _busy = false;

  PluginsController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _repositories = RulesRepositoryConfig.repositories();
    // Rule counts come from the aggregated catalog; load it if the page is
    // opened before anything else touched it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshCatalog());
    });
  }

  /// Applies a configuration change: persist, drop the cached catalog and
  /// reload it, then report the outcome.
  ///
  /// A failed reload is *not* rolled back — the user may simply be offline, and
  /// silently reverting would make the next attempt even more confusing.
  Future<void> _apply(
    Future<List<RuleRepository>> Function() change, {
    required String successMessage,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final updated = await change();
      if (!mounted) return;
      setState(() => _repositories = updated);
      _controller.invalidatePluginCatalog();
      await _refreshCatalog();
      if (!mounted) return;
      _reportReload(successMessage);
    } on FormatException catch (error) {
      if (mounted) setState(() => _repositories = RulesRepositoryConfig.repositories());
      KazumiDialog.showToast(message: error.message);
    } catch (_) {
      // Re-read storage so an optimistic reorder cannot leave the list showing
      // an order that was never persisted.
      if (mounted) setState(() => _repositories = RulesRepositoryConfig.repositories());
      KazumiDialog.showToast(message: '保存规则仓库失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reloads the catalog, swallowing the "nothing reachable" error because the
  /// management page cares about configuration, not about network health.
  Future<void> _refreshCatalog() async {
    try {
      await _controller.refreshPluginCatalog();
    } catch (_) {
      // Reported by [_reportReload] through controller.repositoryFailures.
    }
  }

  void _reportReload(String successMessage) {
    final failures = _controller.repositoryFailures;
    final enabled = _repositories.where((repository) => repository.enabled);
    if (enabled.isEmpty) {
      KazumiDialog.showToast(message: '$successMessage，所有仓库已关闭');
      return;
    }
    if (failures.length >= enabled.length) {
      KazumiDialog.showToast(message: '$successMessage，但目录加载失败');
      return;
    }
    if (failures.isNotEmpty) {
      KazumiDialog.showToast(message: '$successMessage，但部分仓库无法访问');
      return;
    }
    KazumiDialog.showToast(message: successMessage);
  }

  Future<void> _toggle(RuleRepository repository, bool enabled) async {
    await _apply(
      () => RulesRepositoryConfig.replace(
        repository.url,
        repository.copyWith(enabled: enabled),
      ),
      successMessage: enabled ? '已启用 ${repository.displayLabel}' : '已关闭 ${repository.displayLabel}',
    );
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    // The built-in repositories are pinned at the front: the official address is
    // what the mirror interceptor and [ApiEndpoints] constants still point at,
    // and the personal one is defined to sit right behind it. Letting either
    // move would make the two listed first a lie on the next decode.
    final pinned = _repositories.takeWhile((repo) => repo.isBuiltIn).length;
    if (oldIndex < pinned) return;
    // [ReorderableListView.onReorderItem] hands over an index that is already
    // adjusted for the removal, so no offset fix-up is needed here.
    final target = newIndex < pinned ? pinned : newIndex;
    if (target == oldIndex) return;
    final next = [..._repositories];
    final moved = next.removeAt(oldIndex);
    next.insert(target, moved);
    setState(() => _repositories = next);
    await _apply(
      () => RulesRepositoryConfig.save(next).then((_) => next),
      successMessage: '仓库顺序已更新',
    );
  }

  Future<void> _add() async {
    final existing = {for (final repository in _repositories) repository.url};
    final created = await KazumiDialog.show<RuleRepository>(
      builder: (context) => _RepositoryEditorDialog(
        title: '添加规则仓库',
        existingUrls: existing,
      ),
    );
    if (created == null || !mounted) return;
    await _apply(
      () => RulesRepositoryConfig.add(created),
      successMessage: '已保存',
    );
  }

  Future<void> _edit(RuleRepository repository) async {
    final existing = {
      for (final other in _repositories)
        if (other.url != repository.url) other.url,
    };
    final updated = await KazumiDialog.show<RuleRepository>(
      builder: (context) => _RepositoryEditorDialog(
        title: '编辑规则仓库',
        initial: repository,
        existingUrls: existing,
      ),
    );
    if (updated == null || !mounted) return;
    if (updated == repository) return;
    await _apply(
      () => RulesRepositoryConfig.replace(repository.url, updated),
      successMessage: '已保存',
    );
  }

  Future<void> _remove(RuleRepository repository) async {
    final confirmed = await KazumiDialog.show<bool>(
      builder: (context) => AlertDialog(
        title: const Text('删除规则仓库'),
        content: Text(
          '删除「${repository.displayLabel}」？'
          '从该仓库安装的规则不会被删除，但之后无法再从它更新。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _apply(
      () => RulesRepositoryConfig.remove(repository.url),
      successMessage: '已删除',
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('规则仓库管理'),
      actions: [
        IconButton(
          tooltip: '添加规则仓库',
          onPressed: _busy ? null : _add,
          icon: const Icon(Icons.add_rounded),
        ),
        const SizedBox(width: 8),
      ],
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            // The list is never empty: [RuleRepositoryList.decode] restores the
            // built-in repositories whenever storage holds nothing, and they
            // cannot be deleted. Reordering is therefore always meaningful and
            // no empty state is needed here.
            child: Observer(builder: (context) {
              // Reading the observable list here is what subscribes this
              // Observer to catalog changes; [repositoryFailures] is set in the
              // same pass, so it needs no tracking of its own.
              final catalog = _controller.pluginHTTPList;
              final failures = {
                for (final failure in _controller.repositoryFailures)
                  failure.repositoryUrl: failure,
              };
              return ReorderableListView.builder(
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                itemCount: _repositories.length,
                onReorderItem: _busy
                    ? (_, _) {}
                    : (oldIndex, newIndex) =>
                        unawaited(_reorder(oldIndex, newIndex)),
                footer: const _RepositoryFooter(),
                itemBuilder: (context, index) {
                  final repository = _repositories[index];
                  return _RepositoryTile(
                    key: ValueKey(repository.url),
                    index: index,
                    repository: repository,
                    busy: _busy,
                    ruleCount: _ruleCountFor(repository.url, catalog),
                    failed: failures.containsKey(repository.url),
                    onToggle: (enabled) => _toggle(repository, enabled),
                    onEdit: () => _edit(repository),
                    onDelete: repository.isBuiltIn
                        ? null
                        : () => _remove(repository),
                  );
                },
              );
            }),
          ),
        ),
      ),
    );
  }

  /// Number of catalog entries currently attributed to [url].
  ///
  /// Only the winners of same-name conflicts carry a repository tag, so this
  /// undercounts when two repositories list the same rule. That is fine: the
  /// number is a hint that the repository is reachable and non-empty.
  int _ruleCountFor(String url, List<PluginHTTPItem> catalog) {
    if (!_controller.isPluginCatalogFresh) return -1;
    return catalog.where((item) => item.repositoryUrl == url).length;
  }
}

class _RepositoryTile extends StatelessWidget {
  const _RepositoryTile({
    super.key,
    required this.index,
    required this.repository,
    required this.busy,
    required this.ruleCount,
    required this.failed,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final int index;
  final RuleRepository repository;
  final bool busy;
  final int ruleCount;
  final bool failed;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final title = repository.label.isNotEmpty
        ? repository.label
        : repository.isOfficial
            ? '官方规则仓库'
            : repository.isPersonal
                ? '个人规则仓库'
                : repository.displayLabel;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
          child: Row(children: [
            if (repository.isBuiltIn)
              const SizedBox(width: 12)
            else
              ReorderableDragStartListener(
                index: index,
                enabled: !busy,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(Icons.drag_handle_rounded,
                      size: 20, color: colors.onSurfaceVariant),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  // Full address, tappable to copy: the usual reason to look at
                  // it is to compare or tweak it somewhere else.
                  InkWell(
                    onTap: () => _copyAddress(context),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        repository.url,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  _statusLine(theme, colors),
                ],
              ),
            ),
            Switch(
              value: repository.enabled,
              onChanged: busy ? null : onToggle,
            ),
            KazumiMenuButton(
              enabled: !busy,
              builder: (context, toggle) => IconButton(
                tooltip: '更多操作',
                onPressed: toggle,
                icon: const Icon(Icons.more_vert_rounded),
              ),
              menuChildren: [
                KazumiMenuItem(
                  label: '编辑',
                  leadingIcon: const Icon(Icons.edit_outlined),
                  onPressed: onEdit,
                ),
                if (onDelete != null)
                  KazumiMenuItem(
                    label: '删除',
                    destructive: true,
                    leadingIcon: const Icon(Icons.delete_outline_rounded),
                    onPressed: onDelete,
                  ),
              ],
            ),
            const SizedBox(width: 4),
          ]),
        ),
      ),
    );
  }

  Widget _statusLine(ThemeData theme, ColorScheme colors) {
    if (!repository.enabled) {
      return Text('已关闭',
          style: theme.textTheme.bodySmall?.copyWith(color: colors.outline));
    }
    if (failed) {
      return Text('无法访问',
          style: theme.textTheme.bodySmall?.copyWith(color: colors.error));
    }
    if (ruleCount < 0) {
      return Text('尚未加载',
          style:
              theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant));
    }
    return Text('$ruleCount 条规则',
        style:
            theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant));
  }

  Future<void> _copyAddress(BuildContext context) async {
    try {
      await Clipboard.setData(ClipboardData(text: repository.url));
      if (!context.mounted) return;
      KazumiDialog.showToast(context: context, message: '仓库地址已复制');
    } catch (_) {
      if (!context.mounted) return;
      KazumiDialog.showToast(context: context, message: '复制失败，请重试');
    }
  }
}

class _RepositoryFooter extends StatelessWidget {
  const _RepositoryFooter();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16, left: 4, right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.shield_outlined, size: 18, color: colors.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '仅使用你信任的仓库。第三方规则会访问其声明的网站和接口。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.sort_rounded, size: 18, color: colors.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '拖动调整顺序，靠前的仓库优先提供同名规则。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

/// Add / edit dialog.
///
/// The text controllers live in this State and are released in [dispose]:
/// `KazumiDialog.show`'s future completes on `Route.didPop`, which happens
/// before the subtree is torn down, so a controller disposed right after the
/// await would still be attached to a live TextField.
class _RepositoryEditorDialog extends StatefulWidget {
  const _RepositoryEditorDialog({
    required this.title,
    this.initial,
    required this.existingUrls,
  });

  final String title;
  final RuleRepository? initial;
  final Set<String> existingUrls;

  @override
  State<_RepositoryEditorDialog> createState() => _RepositoryEditorDialogState();
}

class _RepositoryEditorDialogState extends State<_RepositoryEditorDialog> {
  late final TextEditingController _label;
  late final TextEditingController _url;
  String? _error;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: widget.initial?.label ?? '');
    // Pre-fill the full catalog address rather than the stored directory, so the
    // field shows the URL the user actually pasted (`.../main/index.json`) and
    // it can be copied straight into a browser. [baseUri] trims it back to the
    // directory on submit.
    _url = TextEditingController(
      text: widget.initial == null
          ? ''
          : RulesRepositoryConfig.catalogUri(widget.initial!.url),
    );
  }

  @override
  void dispose() {
    _label.dispose();
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    final String normalized;
    try {
      normalized = RulesRepositoryConfig.baseUri(_url.text);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    if (widget.existingUrls.contains(normalized)) {
      setState(() => _error = '该仓库已存在');
      return;
    }
    Navigator.of(context).pop(
      RuleRepository(
        url: normalized,
        label: _label.text.trim(),
        enabled: widget.initial?.enabled ?? true,
      ),
    );
  }

  Future<void> _pasteAddress() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      KazumiDialog.showToast(context: context, message: '剪贴板为空');
      return;
    }
    if (text.length > RulesRepositoryConfig.maxUrlLength) {
      setState(() => _error = '仓库地址过长');
      return;
    }
    _url.text = text;
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      // The address field grows with its content, so a long URL can push the
      // dialog past the screen. Scrolling keeps the actions reachable.
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _label,
              textInputAction: TextInputAction.next,
              decoration: ruleInputDecoration(context, label: '名称（可选）'),
            ),
            const SizedBox(height: 12),
            Text(
              '填写包含 index.json 的目录，或直接粘贴 index.json 的完整地址',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            // A tall fixed box rather than a one-line field: long repository
            // addresses wrap inside it, and the height stays put so the
            // dialog does not jump around while typing.
            TextField(
              controller: _url,
              autofocus: true,
              minLines: 4,
              maxLines: 8,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              decoration: ruleInputDecoration(
                context,
                label: '仓库地址',
                hint: '在这里粘贴仓库地址',
              ).copyWith(
                alignLabelWithHint: true,
                errorText: _error,
                errorMaxLines: 4,
                suffixIcon: IconButton(
                  tooltip: '粘贴',
                  icon: const Icon(Icons.content_paste_rounded, size: 20),
                  onPressed: _pasteAddress,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
