import 'package:flutter/material.dart';

const double tonalCardRadius = 16;

/// Outline opacity per `elevation` step in dark theme.
///
/// Calibrated so `elevation = 1.5` yields a 10% white ring: dark has no usable
/// shadow, so the outline alone conveys "lifted".
const double _darkOutlineAlphaPerLevel = 0.10 / 1.5;

/// Outline opacity per `elevation` step in light theme.
///
/// A shadow is invisible here: `surfaceContainerLow` sits only 6 greys under
/// `surface` and blur dilutes the shadow to ~3.5% (3 greys). A 30% `outlineVariant`
/// ring spans ~14 greys with a crisp 1px edge; 40% was tried and felt heavy.
const double _lightOutlineAlphaPerLevel = 0.30 / 1.5;

class TonalCard extends StatelessWidget {
  const TonalCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.elevation = 0,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Outline strength; 0 (default) keeps the flat `surfaceContainerLow` block.
  ///
  /// 19 call sites share this widget, so the default must not change. Light rings
  /// with `outlineVariant`, dark with a faint white glow; see the constants above.
  final double elevation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final lifted = elevation > 0;
    final radius = BorderRadius.circular(tonalCardRadius);

    final outlineColor = dark
        ? Colors.white.withValues(alpha: _darkOutlineAlphaPerLevel * elevation)
        : theme.colorScheme.outlineVariant.withValues(
            alpha: _lightOutlineAlphaPerLevel * elevation,
          );

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      // `shape` and `borderRadius` are exclusive in `Material` (material.dart:209);
      // a flat card passes `BorderSide.none`, which costs no layout.
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: lifted ? BorderSide(color: outlineColor) : BorderSide.none,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
