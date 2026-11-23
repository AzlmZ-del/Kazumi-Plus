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

  /// Vertical gap between cards. Pages override it to match their density.
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

/// Header height of the sync collapse cards (dp), pinned to the 72dp two-line
/// `ListTile` default (`list_tile.dart:1503`). A floor only: `_computeSizes`
/// grows past it when large text does not fit (`list_tile.dart:1662`).
const double kSyncCardTileHeight = 72;

/// Outline strength for the sync cards, passed to `TonalCard.elevation`.
///
/// 1.5 is the second step; the first release used 1 and read too weak.
const double kSyncCardElevation = 1.5;

/// Action button height on the sync page (dp); width comes from the parent.
///
/// Chosen to match the bundled buttons, with callers adding a 16dp inset to align
/// with `Divider(indent: 16)`.
const double kSyncActionButtonHeight = 40;

/// Shared look for the sync action buttons, matching the pre-redesign
/// `FilledButton.tonalIcon` colors (`filled_button.dart:689-704`), disabled and
/// ripple states included.
ButtonStyle syncActionButtonStyle(BuildContext context) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  return ButtonStyle(
    // Keep the M3 disabled grey; `WidgetStatePropertyAll` would override it.
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

/// Small action button in a card header (for example "test connection").
///
/// Same colors as [syncActionButtonStyle] but 12sp at w500: headers are only 72dp
/// tall, where a 16sp button would tower over the other cards.
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
    textStyle: WidgetStatePropertyAll(
      theme.textTheme.labelLarge?.copyWith(fontSize: 12, height: 1.2),
    ),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
    minimumSize: const WidgetStatePropertyAll(Size(0, 0)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

/// Action button height for side-by-side / compact cases (dp), matching the M3
/// `TextButton` default `Size(64, 40)` (`text_button.dart:362`) so it lines up
/// with `TextButton.icon` siblings.
const double kSyncBundledButtonHeight = 40;

/// [StateActionButton.styleOf] tightened one step: lower `minimumSize`, 8dp padding
/// and `shrinkWrap` so layout matches the visible 40dp. A wrapping `SizedBox` is not
/// enough, since `button_style_button.dart:473-480` takes the larger constraint.
ButtonStyle syncBundledButtonStyle(BuildContext context) {
  return StateActionButton.styleOf(context).copyWith(
    minimumSize: const WidgetStatePropertyAll(
      Size(64, kSyncBundledButtonHeight),
    ),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    ),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
}

/// Subtitle style for `SwitchListTile` inside the expanded card: 12sp to match the
/// header, where `ListTile` would use 14sp (`list_tile.dart:1847`).
///
/// No color on purpose: leaving it out keeps the greying from the `ListTile`
/// `AnimatedDefaultTextStyle` (`list_tile.dart:943`) for disabled states.
TextStyle syncSwitchSubtitleStyle(BuildContext context) {
  final base = Theme.of(context).textTheme.bodySmall!;
  return TextStyle(
    fontSize: base.fontSize,
    fontWeight: base.fontWeight,
    letterSpacing: base.letterSpacing,
    height: base.height,
  );
}

/// Card header title, `bodyLarge` (16sp), matching the `SettingsTile` title on the
/// multi-device page instead of `ExpansionTile`'s `ListTile` defaults.
class SyncCardTitle extends StatelessWidget {
  const SyncCardTitle(this.text, {super.key, this.color});

  final String text;

  /// Overrides the inherited color; hand-built headers have no `ListTile` to
  /// supply the greyed-out state.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final inherited = color ?? DefaultTextStyle.of(context).style.color;
    return Text(text, style: textTheme.bodyLarge?.copyWith(color: inherited));
  }
}

/// Card header subtitle, `bodySmall` (12sp) plus `onSurfaceVariant`, matching the
/// `SettingsTile` description.
///
/// The color is explicit because `ListTile` tints subtitles with `onSurface`.
class SyncCardSubtitle extends StatelessWidget {
  const SyncCardSubtitle(this.text, {super.key, this.color});

  final String text;

  /// Overrides the default `onSurfaceVariant` when a header greys itself out.
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// Collapse chevron: right when collapsed, down when expanded, following the
/// "enable WebDAV" cards rather than `ExpansionTile`'s `expand_more`.
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

/// Sync page action button: full width × `kSyncActionButtonHeight`, accent fill.
///
/// Callers supply the 16dp inset that aligns with `Divider(indent: 16)`.
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

  /// Reserves room for a longer status label so the button does not jump.
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
