import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/services/network/metered_network_service.dart';
import 'package:kazumi/services/player/low_memory_mode.dart';

class LowMemoryModeSettingsTile extends StatelessWidget {
  const LowMemoryModeSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    return _ModeBuilder(builder: (context, mode, isMetered) {
      return SettingsTile(
        leading: Icons.data_saver_on_rounded,
        title: const Text('低内存模式'),
        description: Text(mode.statusDescription(isMetered)),
        value: Text(mode.label),
        trailing: const Icon(Icons.chevron_right_rounded),
        onPressed: (_) => context.pushNamed('/settings/player/low-memory'),
      );
    });
  }
}

class LowMemoryModeSettingsPage extends StatefulWidget {
  const LowMemoryModeSettingsPage({super.key});

  @override
  State<LowMemoryModeSettingsPage> createState() =>
      _LowMemoryModeSettingsPageState();
}

class _LowMemoryModeSettingsPageState extends State<LowMemoryModeSettingsPage> {
  bool _saving = false;

  Future<void> _selectMode(LowMemoryMode? mode) async {
    if (mode == null || _saving) return;
    setState(() => _saving = true);
    try {
      await mode.save();
      if (!mounted) return;
      setState(() => _saving = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      KazumiDialog.showToast(context: context, message: '设置保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('低内存模式'),
      body: _ModeBuilder(builder: (context, mode, isMetered) {
        return SettingsList(
          sections: [
            RadioGroup<LowMemoryMode>(
              groupValue: mode,
              onChanged: _selectMode,
              child: SettingsSection(
                title: Semantics(
                  liveRegion: true,
                  child: Text(mode.statusDescription(isMetered)),
                ),
                tiles: [
                  for (final option in LowMemoryMode.values)
                    SettingsTile<LowMemoryMode>.radioTile(
                      title: Text(option == LowMemoryMode.auto
                          ? '${option.label}（默认）'
                          : option.label),
                      description: Text(option.description),
                      radioValue: option,
                      enabled: !_saving,
                    ),
                ],
                bottomInfo: Text(
                  '减少缓存可降低内存占用和额外流量，网络不稳定时可能更容易缓冲。'
                  '\n选择后立即生效并记住选择；跟随网络仅影响在线播放。',
                ),
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _ModeBuilder extends StatefulWidget {
  const _ModeBuilder({required this.builder});

  final Widget Function(BuildContext, LowMemoryMode, bool) builder;

  @override
  State<_ModeBuilder> createState() => _ModeBuilderState();
}

extension _ModePresentation on LowMemoryMode {
  String get label => switch (this) {
        LowMemoryMode.auto => '跟随网络',
        LowMemoryMode.always => '始终开启',
        LowMemoryMode.never => '始终关闭',
      };

  String get description => switch (this) {
        LowMemoryMode.auto => '移动数据自动开启，WLAN / 有线网络自动关闭',
        LowMemoryMode.always => '所有网络均减少缓存，降低内存占用',
        LowMemoryMode.never => '使用完整缓存，移动数据下也不自动开启',
      };

  String statusDescription(bool isMetered) => switch (this) {
        LowMemoryMode.auto =>
          isMetered ? '已自动开启 · 移动数据下减少缓存' : '已自动关闭 · 非移动网络使用完整缓存',
        LowMemoryMode.always => '已手动开启 · 所有网络均减少缓存',
        LowMemoryMode.never =>
          isMetered ? '已手动关闭 · 移动数据使用完整缓存' : '已手动关闭 · 使用完整缓存',
      };
}

class _ModeBuilderState extends State<_ModeBuilder> {
  late final Stream<void> _settingsChanges = LowMemoryMode.watch();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: _settingsChanges,
      builder: (context, _) => ValueListenableBuilder<bool>(
        valueListenable: MeteredNetworkService.listenable,
        builder: (context, isMetered, _) =>
            widget.builder(context, LowMemoryMode.current, isMetered),
      ),
    );
  }
}
