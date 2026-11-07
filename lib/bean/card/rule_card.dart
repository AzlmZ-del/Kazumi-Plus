import 'package:flutter/material.dart';

class RuleCard extends StatelessWidget {
  const RuleCard({
    super.key,
    required this.title,
    this.titleTag,
    this.subtitleTag,
    this.stackedTags = const [],
    this.tags = const [],
    this.caption,
    this.subtitle,
    this.source,
    this.onSourceTap,
    this.webUrl,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.installed = false,
    this.updatable = false,
  });

  final String title;

  /// 右上角，与 [title] 同行右对齐。
  final Widget? titleTag;

  /// 与 [titleTag] 同列，贴在 [subtitle] 行右侧。
  final Widget? subtitleTag;

  /// 继续往下堆叠在右列的同规格 chip（如「直连」），与版本号右边缘对齐。
  final List<Widget> stackedTags;

  final List<Widget> tags;
  final String? caption;
  final String? subtitle;

  /// 有可用更新时把标题染色（替代「可更新」标签）。
  final bool updatable;

  /// 规则来源，单独一行（不占 chip 位）。
  final String? source;

  final VoidCallback? onSourceTap;

  /// 换行不省略：截断的 base URL 无法辨认主机。
  final String? webUrl;

  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool installed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final actions = trailing == null
        ? null
        : Focus(
            parentNode: Focus.maybeOf(context, scopeOk: true),
            canRequestFocus: false,
            skipTraversal: true,
            child: trailing!,
          );
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        selected: selected,
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeInOutCubicEmphasized,
          decoration: BoxDecoration(
            color: selected
                ? colors.secondaryContainer
                : colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(selected ? 20 : 28),
            border: Border.all(
              color: selected ? colors.secondary : Colors.transparent,
              width: 2,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(selected ? 18 : 26),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                      AnimatedContainer(
                        duration: duration,
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: selected || installed
                              ? colors.secondaryContainer
                              : colors.primaryContainer,
                          borderRadius:
                              BorderRadius.circular(installed ? 24 : 16),
                        ),
                        child: Icon(
                          selected
                              ? Icons.check_rounded
                              : Icons.extension_rounded,
                          color: selected || installed
                              ? colors.onSecondaryContainer
                              : colors.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 三枚 chip 统一行高，行距 2。
                            SizedBox(
                              height: 18,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Text(title,
                                        // 压行高收窄两个 chip 的间距；<1.1 中文贴边。
                                        style: text.titleMedium?.copyWith(
                                            fontWeight: FontWeight.w700,
                                            height: 1.2,
                                            // 有更新时标题染色，替代原来的「可更新」标签。
                                            color: updatable
                                                ? colors.primary
                                                : null),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                  if (titleTag != null) ...[
                                    const SizedBox(width: 8),
                                    titleTag!,
                                  ],
                                ],
                              ),
                            ),
                            if (subtitle != null && subtitle!.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              SizedBox(
                                height: 18,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: Text(subtitle!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          // 收紧副标题行；<1.1 中文贴边。
                                          style: text.bodySmall?.copyWith(
                                              color: colors.onSurfaceVariant,
                                              height: 1.15)),
                                    ),
                                    if (subtitleTag != null) ...[
                                      const SizedBox(width: 8),
                                      subtitleTag!,
                                    ],
                                  ],
                                ),
                              ),
                            ],
                            // 直连 chip 与「来源」同行：右列同规格，右对齐；
                            // 源未声明直连时该行只有来源文字。
                            // 行前间距与行高均与上两行统一（2/18），保证三枚
                            // chip 的上下间隔一致。
                            if ((stackedTags.isNotEmpty ||
                                    (source != null && source!.isNotEmpty))) ...[
                              const SizedBox(height: 2),
                              SizedBox(
                                height: 18,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: source != null && source!.isNotEmpty
                                          ? GestureDetector(
                                              onTap: onSourceTap,
                                              child: Text(
                                                '来源 · $source',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: text.bodySmall?.copyWith(
                                                  color: colors.onSurfaceVariant,
                                                  decoration: onSourceTap == null
                                                      ? null
                                                      : TextDecoration.underline,
                                                  decorationStyle:
                                                      TextDecorationStyle.dotted,
                                                ),
                                              ),
                                            )
                                          : const SizedBox.shrink(),
                                    ),
                                    for (final tag in stackedTags) ...[
                                      const SizedBox(width: 8),
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: tag,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                            if (webUrl != null && webUrl!.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                '网址 · $webUrl',
                                style: text.bodySmall?.copyWith(
                                    color: colors.onSurfaceVariant),
                              ),
                            ],
                            if (caption != null) ...[
                              const SizedBox(height: 6),
                              Text(caption!,
                                  style: text.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant)),
                            ],
                            // 状态标签与操作按钮同一行，行高锁 32 免得被 48px 拖拽手柄撑高。
                            if (tags.isNotEmpty || actions != null) ...[
                              const SizedBox(height: 4),
                              SizedBox(
                                height: 32,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    if (tags.isNotEmpty)
                                      Expanded(
                                        child: Wrap(
                                          spacing: 6,
                                          runSpacing: 6,
                                          alignment: WrapAlignment.start,
                                          children: tags,
                                        ),
                                      )
                                    else
                                      const Spacer(),
                                    ?actions,
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RuleTag extends StatelessWidget {
  const RuleTag({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
    this.width,
    this.height,
    this.radius = 8,
    this.fontSize,
  });

  final String label;
  final Color background;
  final Color foreground;

  /// 固定尺寸；同组标签必须用同一组数值才对得齐。
  final double? width;
  final double? height;

  final double radius;

  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.labelSmall;
    final text = Text(label,
        style: base?.copyWith(
            color: foreground,
            fontWeight: FontWeight.w600,
            fontSize: fontSize));
    final decoration = BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(radius),
    );
    if (width == null && height == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: decoration,
        child: text,
      );
    }
    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: decoration,
      child: text,
    );
  }
}
