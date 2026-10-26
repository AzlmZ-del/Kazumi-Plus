import 'package:flutter/material.dart';

import 'package:kazumi/bean/widget/state_presentation.dart';

class SyncPageBody extends StatelessWidget {
  const SyncPageBody({
    super.key,
    required this.children,
    this.maxWidth = 880,
    this.spacing = 20,
  });

  final List<Widget> children;
  final double maxWidth;

  /// 卡片之间的垂直间距。各页可按自身信息密度覆盖默认值。
  final double spacing;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: spacing,
            children: children,
          ),
        ),
      ),
    ),
  );
}

class SyncPageIntro extends StatelessWidget {
  const SyncPageIntro({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StateIconBadge(
            icon: icon,
            size: 64,
            iconSize: 28,
            backgroundColor: theme.colorScheme.primaryContainer,
            foregroundColor: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(title, style: theme.textTheme.headlineSmall),
                ),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 同步设置页折叠卡片的头部固定高度（dp）。
///
/// `ListTile` 两行内容的默认高度本来就是 72（`list_tile.dart:1503` 的
/// `_defaultTileHeight`，`(false, true) => 72.0`），这里显式写出来是为了
/// **把契约钉住**：以后谁改了标题/副标题字号，也不用重新算一遍会不会变矮。
///
/// ⚠️ 它不是硬约束。`_computeSizes` 在内容放不下时会走 `compact` 分支
/// （`list_tile.dart:1662`），高度变成 `2×minVerticalPadding + 标题高 + 副标题高`，
/// 比 72 还大 —— 系统字体放大到 1.5 倍以上就会触发。这是**故意留的**：
/// 与其把文字裁掉，不如让卡片长高。
const double kSyncCardTileHeight = 72;

/// 同步设置页折叠卡片的立体感强度，传给 `TonalCard.elevation`。
///
/// 1.5 是第二档（第一版用 1，用户觉得偏弱）：亮色下投影 7% 黑、
/// 模糊 13px、下移 3.25px；深色下改画 10% 白光描边（黑底上黑影是隐形的）。
const double kSyncCardElevation = 1.5;

/// 同步设置页动作按钮的高度（dp）。宽度不锁死，由父级拉伸到整行。
const double kSyncActionButtonHeight = 48;

/// 同步设置页动作按钮的统一外观：与未改版前的 `FilledButton.tonalIcon` 同配色
/// （`secondaryContainer` 底 + `onSecondaryContainer` 字），
/// 字号用 `bodyLarge`（16sp），和 `SyncCardTitle` 完全一致。
///
/// 配色取值照抄 `filled_button.dart:689-704` 的 `_FilledTonalButtonDefaultsM3`，
/// 连禁用态和 `overlayColor` 一起搬过来，保证按下/悬停的水波纹也是原来的观感。
ButtonStyle syncActionButtonStyle(BuildContext context) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  return ButtonStyle(
    // 禁用态沿用 M3 的灰，避免 `WidgetStatePropertyAll` 把禁用样式一起盖掉。
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? colors.onSurface.withValues(alpha: 0.12)
          : colors.secondaryContainer,
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? colors.onSurface.withValues(alpha: 0.38)
          : colors.onSecondaryContainer,
    ),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return colors.onSecondaryContainer.withValues(alpha: 0.1);
      }
      if (states.contains(WidgetState.hovered)) {
        return colors.onSecondaryContainer.withValues(alpha: 0.08);
      }
      if (states.contains(WidgetState.focused)) {
        return colors.onSecondaryContainer.withValues(alpha: 0.1);
      }
      return null;
    }),
    textStyle: WidgetStatePropertyAll(theme.textTheme.bodyLarge),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
  );
}

/// 卡片头部里的小号动作按钮（如「测试连接」）。
///
/// 与 `syncActionButtonStyle` 同配色，但字号降到 `labelLarge`（14sp）、
/// 左右内边距 12dp、圆角 16dp —— 卡片头部只有 72dp 高，
/// 用 16sp 的大按钮会把标题栏顶得比别的卡高。
ButtonStyle syncHeaderButtonStyle(BuildContext context) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  return ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? colors.onSurface.withValues(alpha: 0.12)
          : colors.secondaryContainer,
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? colors.onSurface.withValues(alpha: 0.38)
          : colors.onSecondaryContainer,
    ),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return colors.onSecondaryContainer.withValues(alpha: 0.1);
      }
      if (states.contains(WidgetState.hovered)) {
        return colors.onSecondaryContainer.withValues(alpha: 0.08);
      }
      if (states.contains(WidgetState.focused)) {
        return colors.onSecondaryContainer.withValues(alpha: 0.1);
      }
      return null;
    }),
    textStyle: WidgetStatePropertyAll(theme.textTheme.labelLarge),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
    minimumSize: const WidgetStatePropertyAll(Size(0, 0)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}

/// 卡片展开区里 `SwitchListTile` 的副标题样式：**12sp**。
///
/// `ListTile` 默认副标题是 `bodyMedium`（14sp，`list_tile.dart:1847`），
/// 比卡片头部的 `SyncCardSubtitle`（12sp）大一档，同一张卡里会一粗一细。
/// 这里压到 12sp，与卡片头部对齐。
///
/// 注意**不给颜色**：`SwitchListTile` 没有 `subtitleTextStyle` 参数
/// （`switch_list_tile.dart:173-221` 的构造参数表里没有这一项，传了编译不过），
/// 只能把样式挂到 `subtitle` 那个 `Text` 上。
/// 而 `TextStyle.inherit` 默认为 true，`Text` 会把自身样式 **merge** 到
/// 外层 `AnimatedDefaultTextStyle`（`list_tile.dart:943`）之上 ——
/// 只要这里不写 `color`，颜色就仍由 `ListTile` 的 `effectiveColor` 决定，
/// 同步中 / 未配置时的置灰效果照旧。
TextStyle syncSwitchSubtitleStyle(BuildContext context) {
  final base = Theme.of(context).textTheme.bodySmall!;
  return TextStyle(
    fontSize: base.fontSize,
    fontWeight: base.fontWeight,
    letterSpacing: base.letterSpacing,
    height: base.height,
  );
}

/// 卡片头部的主标题，与「多设备同步」页 `SettingsTile` 的 title 同款：
/// `bodyLarge`（16sp / 行高 1.50）。
///
/// 之所以要显式指定，是因为 `ExpansionTile` 走的是 `ListTile` 默认样式
/// （`list_tile.dart:1844` 的 `bodyLarge`），但副标题是 `bodyMedium`（14sp），
/// 与 `SettingsTile` 的 12sp 不一致；两个页面的卡片头部看起来就会差一档。
class SyncCardTitle extends StatelessWidget {
  const SyncCardTitle(this.text, {super.key, this.color});

  final String text;

  /// 显式指定颜色。不传时沿用外层 `ListTile` 算好的那个
  /// （`AnimatedDefaultTextStyle` 传下来的），这样卡片被禁用时仍然是灰的。
  ///
  /// 自绘头部（如「启用 WebDAV」卡片）没有 `ListTile` 兜底，
  /// 需要自己传颜色，才能保住「未配置时置灰」的效果。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // 颜色沿用外层 `ListTile` 算好的那个（`AnimatedDefaultTextStyle` 传下来的），
    // 这样将来卡片被禁用时仍然是灰色的，不会被写死的颜色盖掉。
    final inherited = color ?? DefaultTextStyle.of(context).style.color;
    return Text(text, style: textTheme.bodyLarge?.copyWith(color: inherited));
  }
}

/// 卡片头部的副标题，与 `SettingsTile` 的 description 同款：
/// `bodySmall`（12sp / 行高 1.33）+ `onSurfaceVariant` 灰色。
///
/// `ListTile` 默认把副标题染成和主标题一样的 `onSurface`
/// （`list_tile.dart:938` 的 `subtitleColor = effectiveColor`），
/// 所以颜色也必须显式给，否则只有字号对了、层次还是平的。
class SyncCardSubtitle extends StatelessWidget {
  const SyncCardSubtitle(this.text, {super.key, this.color});

  final String text;

  /// 显式指定颜色。不传时用 `onSurfaceVariant`（与 `SettingsTile` 的
  /// description 一致）。自绘头部需要置灰时自己传。
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// 折叠卡片右侧的箭头：收起时朝右，展开时顺时针转 90° 朝下。
///
/// `ExpansionTile` 默认的 `trailing` 是 `expand_more`（朝下），与本页其余
/// 卡片（如「启用 WebDAV」）的「右 → 下」习惯不一致，所以统一换成这个。
class SyncExpandChevron extends StatelessWidget {
  const SyncExpandChevron({super.key, required this.expanded, this.color});

  final bool expanded;
  final Color? color;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: expanded ? 0.25 : 0,
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200),
    child: Icon(Icons.chevron_right_rounded, size: 24, color: color),
  );
}

/// 同步设置页的动作按钮：撑满整行 × `kSyncActionButtonHeight`、强调色底、白字、
/// 与卡片主标题同字号。
///
/// 宽度用 `double.infinity` 交给父级决定，两个调用方都是
/// `CrossAxisAlignment.stretch` 的列/展开区，所以拿到的就是「整行宽度」。
/// 不写死数值的好处：换机型、改页面左右内边距、桌面端拉宽窗口都自动跟着变。
class SyncActionButton extends StatelessWidget {
  const SyncActionButton({
    super.key,
    required this.onPressed,
    required this.text,
    this.icon,
    this.reserveText,
  });

  final VoidCallback? onPressed;
  final String text;
  final IconData? icon;

  /// 预留更长的状态文案宽度，避免切换文字时按钮跳动。
  final String? reserveText;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: kSyncActionButtonHeight,
    child: StateActionButton(
      onPressed: onPressed,
      text: text,
      icon: icon,
      reserveText: reserveText,
      style: syncActionButtonStyle(context),
    ),
  );
}

class SyncFeedback extends StatelessWidget {
  const SyncFeedback({
    super.key,
    required this.message,
    this.error = false,
    this.busy = false,
    this.progress,
  });

  final String message;
  final bool error;
  final bool busy;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: error ? colors.errorContainer : colors.secondaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  error
                      ? Icons.error_outline_rounded
                      : busy
                      ? Icons.sync_rounded
                      : Icons.check_circle_outline_rounded,
                  size: 20,
                  color: error
                      ? colors.onErrorContainer
                      : colors.onSecondaryContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: error
                          ? colors.onErrorContainer
                          : colors.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            if (busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progress),
            ],
          ],
        ),
      ),
    );
  }
}
