import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/services/network/acceleration_mode.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:kazumi/services/network/image_acceleration.dart';
import 'package:kazumi/services/network/image_quality.dart';
import 'package:kazumi/services/network/rules_mirror.dart';
import 'package:kazumi/services/network/rules_mirror_probe.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/speed_tier.dart';

/// 弹出加速档位选择器，各模式列表共用。
///
/// 用户选了与 [current] 不同的档位并写入 [setting] 后返回 true。
///
/// [probe] 非空时打开对话框即并发探测各档位；每测完一个就立刻显示这一条，
/// 不等待最慢的那个。探测纯内存执行，不落盘，也不替用户改选。
Future<bool> selectAccelerationMode<T extends AccelerationMode>(
  BuildContext context, {
  required String title,
  required T current,
  required List<T> modes,
  required SettingKey<String> setting,
  Future<void> Function(
    void Function(AccelerationProbe result) onResult, {
    bool force,
  })?
  probe,
}) async {
  final selected = await KazumiDialog.show<T>(
    context: context,
    builder: (context) => _AccelerationModeDialog<T>(
      title: title,
      current: current,
      modes: modes,
      probe: probe,
    ),
  );
  if (selected == null || selected == current) {
    return false;
  }
  await GStorage.putSetting(setting, selected.name);
  return true;
}

/// 单个档位的探测结论，按 [AccelerationMode] 的运行时枚举值做键。
class AccelerationProbe {
  const AccelerationProbe({
    required this.mode,
    required this.label,
    this.latencyMillis,
    this.notApplicable = false,
  });

  final Enum mode;
  final String label;

  /// 可达时的耗时毫秒；不可达或不生效率留空，让配色回落到默认色。
  final int? latencyMillis;

  /// 该档位对当前仓库不生效（例如 GitCode 不镜像个人仓库）。
  final bool notApplicable;

  factory AccelerationProbe.fromResult(RulesMirrorProbeResult result) {
    return AccelerationProbe(
      mode: result.mode,
      label: result.label,
      latencyMillis: result.reachable && !result.notApplicable
          ? result.latency.inMilliseconds
          : null,
      notApplicable: result.notApplicable,
    );
  }
}

class _AccelerationModeDialog<T extends AccelerationMode>
    extends StatefulWidget {
  const _AccelerationModeDialog({
    required this.title,
    required this.current,
    required this.modes,
    this.probe,
  });

  final String title;
  final T current;
  final List<T> modes;

  /// 逐条回调：每测完一个档位就调一次 [onResult]，界面立刻显示这一条。
  /// [force] 为 true 表示用户主动重测，应跳过缓存。
  final Future<void> Function(
    void Function(AccelerationProbe result) onResult, {
    bool force,
  })?
  probe;

  @override
  State<_AccelerationModeDialog<T>> createState() =>
      _AccelerationModeDialogState<T>();
}

class _AccelerationModeDialogState<T extends AccelerationMode>
    extends State<_AccelerationModeDialog<T>> {
  Map<Enum, AccelerationProbe> _probes = const {};
  bool _probing = false;

  /// 每次重测递增，用来丢弃上一轮迟到的回调。
  int _probeGeneration = 0;

  @override
  void initState() {
    super.initState();
    // 只有带探测的对话框才进入「测速中」；其余（番剧条目、图片加速等）
    // 本来就没有测速，置 true 会让它们一直卡在「测速中…」。
    if (widget.probe == null) {
      return;
    }
    _probing = true;
    _startProbe();
  }

  // 打开时先吃缓存；标题栏的闪电按钮强制重测，跳过缓存。
  void _startProbe({bool force = false}) {
    final probe = widget.probe;
    if (probe == null) {
      return;
    }
    final generation = ++_probeGeneration;
    _probes = const {};
    unawaited(
      probe((result) {
            // 上一轮还没回来就重测时，旧结果不能盖到新一轮上。
            if (!mounted || generation != _probeGeneration) {
              return;
            }
            setState(() {
              _probes = {..._probes, result.mode: result};
            });
          }, force: force)
          .then((_) {
            if (!mounted || generation != _probeGeneration) {
              return;
            }
            setState(() => _probing = false);
          })
          .catchError((Object _) {
            if (mounted && generation == _probeGeneration) {
              setState(() => _probing = false);
            }
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SimpleDialog(
      title: Row(
        children: [
          Expanded(child: Text(widget.title)),
          if (widget.probe != null)
            IconButton(
              onPressed: _probing ? null : _retryProbe,
              icon: _probing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bolt_rounded),
              tooltip: '重新检测延迟',
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      children: [
        RadioGroup<T>(
          groupValue: widget.current,
          onChanged: (value) => Navigator.of(context).pop(value),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mode in widget.modes)
                RadioListTile<T>(
                  value: mode,
                  // 标题用 titleMedium（16sp / w500）而不是 bodyLarge：
                  // 后者是 w400，和外层卡片的正文同重，选项看起来没有层次。
                  // 描述保持 bodySmall、间距 2dp；行高靠负竖向密度收紧，
                  // 不用 dense——它会把标题压到和描述同号，主次就没了。
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  visualDensity: const VisualDensity(vertical: -3),
                  title: Text(
                    mode.label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: mode.description),
                          if (_probeSuffix(mode, theme) case final suffix?)
                            TextSpan(
                              text: suffix.text,
                              style: TextStyle(color: suffix.color),
                            ),
                        ],
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  void _retryProbe() {
    setState(() {
      _probing = true;
      _startProbe(force: true);
    });
  }

  /// 延迟后缀：阈值与配色复用 [speedTierOf] / [speedTierColor]，
  /// 与播放来源弹窗、插件测试页保持一致。
  /// 不可达或未出结果时不着色，避免把「测不出来」画成「很慢」。
  ({String text, Color color})? _probeSuffix(T mode, ThemeData theme) {
    if (widget.probe == null) {
      return null;
    }
    final probe = _probes[mode];
    if (probe == null) {
      return _probing
          ? (text: ' · 测速中…', color: theme.colorScheme.onSurfaceVariant)
          : null;
    }
    final tier = speedTierOf(probe.latencyMillis);
    return (
      text: ' · ${probe.label}',
      color: speedTierColor(tier, theme.colorScheme.onSurfaceVariant),
    );
  }
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
    Future<void> Function(
      void Function(AccelerationProbe result) onResult, {
      bool force,
    })?
    probe,
  }) async {
    final changed = await selectAccelerationMode<T>(
      context,
      title: title,
      current: current,
      modes: modes,
      setting: setting,
      probe: probe,
    );
    if (changed && mounted) setState(() {});
  }

  static Future<void> _probeRulesMirror(
    void Function(AccelerationProbe result) onResult, {
    bool force = false,
  }) {
    return RulesMirrorProbe.runCached(
      (result) => onResult(AccelerationProbe.fromResult(result)),
      force: force,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bangumiAcceleration = BangumiAcceleration.current;
    final rulesMirror = RulesMirror.current;
    final imageAcceleration = ImageAcceleration.current;
    final imageQuality = ImageQuality.current;
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
            probe: _probeRulesMirror,
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
        SettingsTile(
          leading: Icons.hd_rounded,
          title: const Text('封面质量'),
          description: const Text(
            '番剧封面分辨率',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          value: SizedBox(
            width: 60,
            child: Text(imageQuality.label, textAlign: TextAlign.center),
          ),
          onPressed: (context) => _pick(
            context,
            title: '封面质量',
            current: imageQuality,
            modes: ImageQuality.values,
            setting: SettingsKeys.imageQuality,
          ),
        ),
      ],
    );
  }
}
