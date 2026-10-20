import 'package:flutter/material.dart';

class RuleCard extends StatelessWidget {
  const RuleCard({
    super.key,
    required this.title,
    this.titleTag,
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
  });

  final String title;

  /// Chip docked in the card's top-right corner, sharing the heading line with
  /// [title] and right-aligned with [trailing].
  ///
  /// Identity-adjacent facts (such as the rule version) read better level with
  /// the name than in the chip row under the URLs, so they get their own slot
  /// and stay put while the [tags] row changes.
  final Widget? titleTag;

  final List<Widget> tags;
  final String? caption;
  final String? subtitle;

  /// Where this rule came from, rendered right under [subtitle].
  ///
  /// A separate line rather than another chip: the source is identity, not a
  /// property of the rule, so it stays put while chips come and go.
  final String? source;

  /// Tapping the source line usually reveals the same-name rules it shadowed.
  final VoidCallback? onSourceTap;

  /// The address the source resolves to, rendered under the source line.
  ///
  /// Wraps instead of ellipsizing on purpose: a truncated base URL is useless
  /// for spotting which host a rule actually comes from.
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
    // Keep menu focus from activating the enclosing InkWell's highlight.
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
    // The version chip and the trailing action share one right-aligned column;
    // the 16px inset puts the chip's edge on the action's label edge instead of
    // floating out to the card border (both action variants pad their labels
    // by 16).
    final side = (titleTag == null && actions == null)
        ? null
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (titleTag != null)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: titleTag!,
                ),
              if (titleTag != null && actions != null)
                const SizedBox(height: 6),
              ?actions,
            ],
          );
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
                padding: const EdgeInsets.all(14),
                child: LayoutBuilder(builder: (context, constraints) {
                  final stacked = constraints.maxWidth < 300 ||
                      MediaQuery.textScalerOf(context).scale(14) > 20;
                  final identity = Row(
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
                            Text(title,
                                style: text.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                            if (subtitle != null && subtitle!.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(subtitle!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant)),
                            ],
                            if (source != null && source!.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              GestureDetector(
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
                            if (tags.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(spacing: 6, runSpacing: 6, children: tags),
                            ],
                            if (caption != null) ...[
                              const SizedBox(height: 6),
                              Text(caption!,
                                  style: text.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant)),
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                  if (stacked) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        identity,
                        if (side != null) ...[
                          const SizedBox(height: 8),
                          Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: side),
                        ],
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: identity),
                      if (side != null) ...[
                        const SizedBox(width: 12),
                        side
                      ],
                    ],
                  );
                }),
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
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: foreground, fontWeight: FontWeight.w600)),
      );
}
