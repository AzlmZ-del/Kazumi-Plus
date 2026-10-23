import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/services/network/acceleration_mode.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:kazumi/services/network/image_acceleration.dart';
import 'package:kazumi/services/network/rules_mirror.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Shows the acceleration picker shared by every mode list.
///
/// Returns true when the user picked a mode different from [current] and it was
/// persisted to [setting].
Future<bool> selectAccelerationMode<T extends AccelerationMode>(
  BuildContext context, {
  required String title,
  required T current,
  required List<T> modes,
  required SettingKey<String> setting,
}) async {
  final selected = await KazumiDialog.show<T>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        RadioGroup<T>(
          groupValue: current,
          onChanged: (value) => Navigator.of(context).pop(value),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mode in modes)
                RadioListTile<T>(
                  value: mode,
                  title: Text(mode.label),
                  subtitle: Text(
                    mode.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
  if (selected == null || selected == current) {
    return false;
  }
  await GStorage.putSetting(setting, selected.name);
  return true;
}

class NetworkMirrorSettings extends StatefulWidget {
  const NetworkMirrorSettings({super.key, this.margin});

  final EdgeInsetsGeometry? margin;

  @override
  State<NetworkMirrorSettings> createState() => _NetworkMirrorSettingsState();
}

class _NetworkMirrorSettingsState extends State<NetworkMirrorSettings> {
  Future<void> _pick<T extends AccelerationMode>(
    BuildContext context, {
    required String title,
    required T current,
    required List<T> modes,
    required SettingKey<String> setting,
  }) async {
    final changed = await selectAccelerationMode<T>(
      context,
      title: title,
      current: current,
      modes: modes,
      setting: setting,
    );
    if (changed && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final bangumiAcceleration = BangumiAcceleration.current;
    final rulesMirror = RulesMirror.current;
    final imageAcceleration = ImageAcceleration.current;
    return SettingsSection(
      title: const Text('访问加速'),
      margin: widget.margin,
      tiles: [
        SettingsTile(
          leading: Icons.travel_explore_rounded,
          title: const Text('番剧条目加速'),
          description: const Text(
            '番剧信息与评论',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          value: SizedBox(
            width: 60,
            child: Text(bangumiAcceleration.label, textAlign: TextAlign.center),
          ),
          onPressed: (context) => _pick(
            context,
            title: '番剧条目加速',
            current: bangumiAcceleration,
            modes: BangumiAcceleration.values,
            setting: SettingsKeys.bangumiAcceleration,
          ),
        ),
        SettingsTile(
          leading: Icons.extension_rounded,
          title: const Text('规则仓库加速'),
          description: const Text(
            '规则列表与规则详情',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          value: SizedBox(
            width: 60,
            child: Text(rulesMirror.label, textAlign: TextAlign.center),
          ),
          onPressed: (context) => _pick(
            context,
            title: '规则仓库加速',
            current: rulesMirror,
            modes: RulesMirror.values,
            setting: SettingsKeys.rulesMirror,
          ),
        ),
        SettingsTile(
          leading: Icons.image_rounded,
          title: const Text('图片加速'),
          description: const Text(
            '封面与头像',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          value: SizedBox(
            width: 60,
            child: Text(imageAcceleration.label, textAlign: TextAlign.center),
          ),
          onPressed: (context) => _pick(
            context,
            title: '图片加速',
            current: imageAcceleration,
            modes: ImageAcceleration.values,
            setting: SettingsKeys.imageAcceleration,
          ),
        ),
      ],
    );
  }
}
