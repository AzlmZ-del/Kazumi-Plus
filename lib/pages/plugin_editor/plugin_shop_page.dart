import 'package:flutter/material.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/pages/plugin_editor/plugin_catalog_view.dart';
import 'package:kazumi/plugins/plugins_controller.dart';

class PluginShopPage extends StatefulWidget {
  const PluginShopPage({super.key, required this.controller});
  final PluginsController controller;

  @override
  State<PluginShopPage> createState() => _PluginShopPageState();
}

class _PluginShopPageState extends State<PluginShopPage> {
  final _catalogKey = GlobalKey<PluginCatalogViewState>();

  @override
  Widget build(BuildContext context) => SettingsDetailScaffold(
        title: const Text('规则仓库'),
        body: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: PluginCatalogView(
                key: _catalogKey,
                controller: widget.controller,
                onManageRepositories: _openRepositories,
              ),
            ),
          ),
        ),
      );

  Future<void> _openRepositories() async {
    await Navigator.of(context).pushNamed('/settings/plugin/shop/repositories');
    if (!mounted) return;
    // The management page may have changed which repositories are enabled; the
    // catalog has to be recomputed, not just re-fetched.
    _catalogKey.currentState?.reload();
  }
}
