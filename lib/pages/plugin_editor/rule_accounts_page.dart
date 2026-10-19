import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/pages/plugin_editor/rule_management_widgets.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/plugin/plugin_credentials_store.dart';

/// Lists the installed rules that declare a login flow and lets the user
/// enter the account each of them needs.
///
/// Credentials stay on this device: they are written to a dedicated Hive box
/// and only ever sent to the rule's own login endpoint.
class RuleAccountsPage extends StatefulWidget {
  const RuleAccountsPage({super.key, required this.controller});

  final PluginsController controller;

  @override
  State<RuleAccountsPage> createState() => _RuleAccountsPageState();
}

class _RuleAccountsPageState extends State<RuleAccountsPage> {
  final PluginCredentialsStore _store = PluginCredentialsStore.instance;

  List<Plugin> get _authRules =>
      widget.controller.pluginList.where((rule) => rule.auth != null).toList();

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('规则账号'),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Observer(builder: (context) {
              final rules = _authRules;
              if (rules.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: GeneralEmptyState(
                    icon: Icons.key_off_rounded,
                    title: '没有需要登录的规则',
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  const RulePageIntro(
                    title: '规则账号',
                    description: '部分规则需要登录后才能取到播放地址。账号只保存在本机，'
                        '仅发送给该规则自己的登录接口。',
                    icon: Icons.key_rounded,
                  ),
                  const SizedBox(height: 16),
                  for (final rule in rules) ...[
                    _AccountCard(
                      plugin: rule,
                      store: _store,
                      onChanged: () => setState(() {}),
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.plugin,
    required this.store,
    required this.onChanged,
  });

  final Plugin plugin;
  final PluginCredentialsStore store;
  final VoidCallback onChanged;

  bool get _configured => store.hasCredentials(plugin.name);

  Future<void> _edit(BuildContext context) async {
    final hadPassword = store.hasCredentials(plugin.name);
    final result = await KazumiDialog.show<_AccountResult>(
      builder: (context) => _AccountDialog(
        pluginName: plugin.name,
        initialUsername: store.usernameFor(plugin.name) ?? '',
        passwordOptional: hadPassword,
        hasStoredPassword: hadPassword,
        initialPassword: hadPassword
            ? (store.passwordFor(plugin.name) ?? '')
            : '',
      ),
    );
    if (result == null) return;
    if (result.password.isEmpty) {
      // The dialog only allows an empty password when one is already stored,
      // and then it means "keep the current one".
      final saved = await store.saveUsername(plugin.name, result.username);
      if (!saved) return;
    } else {
      await store.saveCredentials(
        plugin.name,
        username: result.username,
        password: result.password,
      );
      // A new password invalidates the token obtained with the old one.
      await store.clearToken(plugin.name);
    }
    onChanged();
    if (context.mounted) {
      KazumiDialog.showToast(context: context, message: '账号已保存');
    }
  }

  Future<void> _clear(BuildContext context) async {
    final confirmed = await KazumiDialog.show<bool>(
      builder: (context) => AlertDialog(
        title: const Text('清除账号'),
        content: Text('清除「${plugin.name}」的账号与缓存令牌？'),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => KazumiDialog.dismiss(popWith: true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await store.clearAll(plugin.name);
    onChanged();
    if (context.mounted) {
      KazumiDialog.showToast(context: context, message: '账号已清除');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            Icon(
              _configured ? Icons.key_rounded : Icons.key_off_rounded,
              color: _configured ? colors.primary : colors.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(plugin.name,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    _configured
                        ? '已保存账号 ${store.usernameFor(plugin.name) ?? ''}'
                        : '需要登录',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _configured
                              ? colors.onSurfaceVariant
                              : colors.error,
                        ),
                  ),
                ],
              ),
            ),
            if (_configured)
              IconButton(
                tooltip: '清除账号',
                onPressed: () => unawaited(_clear(context)),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            TextButton(
              onPressed: () => unawaited(_edit(context)),
              child: Text(_configured ? '修改' : '设置账号'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountResult {
  const _AccountResult({required this.username, required this.password});

  final String username;
  final String password;
}

class _AccountDialog extends StatefulWidget {
  const _AccountDialog({
    required this.pluginName,
    required this.initialUsername,
    this.initialPassword = '',
    this.passwordOptional = false,
    this.hasStoredPassword = false,
  });

  final String pluginName;
  final String initialUsername;

  /// When true the password field may be left empty, meaning "keep the
  /// password that is already stored".
  final bool passwordOptional;

  /// Whether a password is already stored; when true the stored password is
  /// pre-filled so the user can confirm what is saved.
  final bool hasStoredPassword;

  /// The stored password to pre-fill, empty when none is saved.
  final String initialPassword;

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  late final TextEditingController _username =
      TextEditingController(text: widget.initialUsername);
  late final TextEditingController _password =
      TextEditingController(text: widget.initialPassword);
  String? _error;

  // The field starts empty; while typing it shows plain text so the user can
  // confirm what they entered, and the eye toggle re-hides it. An empty field
  // with a stored password means "keep the stored one".
  bool _obscured = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _pastePassword() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (!mounted) return;
      if (text.isEmpty) {
        KazumiDialog.showToast(context: context, message: '剪贴板为空');
        return;
      }
      setState(() {
        _password.text = text;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '读取剪贴板失败');
      }
    }
  }

  void _submit() {
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty || (password.isEmpty && !widget.passwordOptional)) {
      setState(() => _error = '请填写账号与密码');
      return;
    }
    KazumiDialog.dismiss(
      popWith: _AccountResult(username: username, password: password),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.pluginName),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _username,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: ruleInputDecoration(context, label: '账号'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: _obscured,
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              decoration: ruleInputDecoration(
                context,
                label: '密码',
                hint: widget.passwordOptional ? '留空则不修改' : null,
              ).copyWith(
                errorText: _error,
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '粘贴密码',
                      icon: const Icon(Icons.content_paste_rounded, size: 20),
                      onPressed: _pastePassword,
                    ),
                    IconButton(
                      tooltip: _obscured ? '显示密码' : '隐藏密码',
                      icon: Icon(
                        _obscured
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _obscured = !_obscured),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '账号保存在本机，只发送给该规则的登录接口。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => KazumiDialog.dismiss(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
