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

/// 管理规则仓库列表：排序、启停、改名、编辑、删除。
///
/// 顺序**就是**优先级：同名规则由第一个启用且声明了它的仓库胜出，
/// 拖拽排序的意义正在于此。
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
    // 规则条数来自聚合后的目录；若本页先于其它地方打开，得先把它加载起来。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshCatalog());
    });
  }

  /// 应用一次配置变更：落盘、丢弃缓存目录并重新加载，最后回报结果。
  ///
  /// 重新加载失败**不会**回滚——用户可能只是离线，
  /// 悄悄改回去只会让下一次尝试更难理解。
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
      // 重新读一次存储，避免乐观排序把列表停在「从未真正落盘」的顺序上。
      if (mounted) setState(() => _repositories = RulesRepositoryConfig.repositories());
      KazumiDialog.showToast(message: '保存规则仓库失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 重新加载目录，并吞掉「一个都连不上」的错误——
  /// 管理页关心的是配置，不是网络状况。
  Future<void> _refreshCatalog() async {
    try {
      await _controller.refreshPluginCatalog();
    } catch (_) {
      // 失败由 [_reportReload] 通过 controller.repositoryFailures 上报。
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
    // 内置仓库固定在队首：镜像拦截器与 [ApiEndpoints] 常量仍指向官方地址，
    // 个人仓库则定义为紧随其后。允许它们挪位，下次解码时「前两个是内置」
    // 这个说法就成假的了。
    final pinned = _repositories.takeWhile((repo) => repo.isBuiltIn).length;
    if (oldIndex < pinned) return;
    // [ReorderableListView.onReorderItem] 给出的下标已经扣除了被移除的那一项，
    // 这里不需要再补偏移。
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
            // 列表不会为空：[RuleRepositoryList.decode] 在存储为空时会补回内置仓库，
            // 而内置仓库不能删除。所以排序永远有意义，这里也不需要空状态。
            child: Observer(builder: (context) {
              // 在这里读一次可观察列表，这个 Observer 才会订阅目录变化；
              // [repositoryFailures] 在同一趟里赋值，无需单独追踪。
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

  /// 当前归属到 [url] 的目录条目数。
  ///
  /// 只有同名冲突中的胜出者才带仓库标记，所以两个仓库列了同一条规则时会少算。
  /// 这没关系：这个数字只是「该仓库可访问且非空」的提示。
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
                  // 完整地址，可点击复制：看它的常见理由就是拿去别处比对或调整。
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

/// 新增 / 编辑对话框。
///
/// 文本控制器放在这个 State 里，在 [dispose] 中释放：
/// `KazumiDialog.show` 的 future 在 `Route.didPop` 时就完成了，而那时子树还没拆，
/// 所以 await 之后立刻 dispose 控制器，它仍会挂在一个活着的 TextField 上。
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
    // 预填完整目录地址而不是存储的目录，这样输入框显示的是用户当初粘贴的 URL
    // （`.../main/index.json`），可以直接复制进浏览器。
    // 提交时 [baseUri] 会把它裁回目录。
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
      // 地址框会随内容增高，长 URL 会把对话框顶出屏幕。
      // 加滚动保证操作按钮始终够得着。
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
            // 用固定高度的多行框而不是单行输入框：长仓库地址在里面折行，
            // 高度固定，输入时对话框不会跟着跳。
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
