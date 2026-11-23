import 'package:flutter/material.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

/// Shared icon edge length for [StateActionButton] (18dp); all icon call sites
/// follow it.
///
/// M3's 20dp reads 30% bulkier than MiSans CJK ink beside it (`0.92 × fontSize`,
/// 12.9dp at 14sp), because Material Icons glyphs nearly fill the box.
const double kStateActionButtonIconSize = 18;

class StateIconBadge extends StatelessWidget {
  const StateIconBadge({
    super.key,
    required this.icon,
    required this.size,
    required this.iconSize,
    required this.backgroundColor,
    required this.foregroundColor,
    this.shape,
  });

  final IconData icon;
  final double size;
  final double iconSize;
  final Color backgroundColor;
  final Color foregroundColor;

  /// Defaults to [MaterialShapes.cookie4Sided].
  final RoundedPolygon? shape;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipPath(
      clipper: _StateShapeClipper(shape ?? MaterialShapes.cookie4Sided),
      child: ColoredBox(
        color: backgroundColor,
        child: SizedBox.square(
          dimension: size,
          child: Icon(icon, size: iconSize, color: foregroundColor),
        ),
      ),
    ),
  );
}

class _StateShapeClipper extends CustomClipper<Path> {
  const _StateShapeClipper(this.shape);

  final RoundedPolygon shape;
  static final _paths = Expando<Path>();

  @override
  Path getClip(Size size) => (_paths[shape] ??= shape.toPath()).transform(
    Matrix4.diagonal3Values(size.width, size.height, 1).storage,
  );

  @override
  bool shouldReclip(_StateShapeClipper oldClipper) => oldClipper.shape != shape;
}

class StateActionButton extends StatelessWidget {
  const StateActionButton({
    super.key,
    required this.onPressed,
    required this.text,
    this.icon,
    this.iconSize = kStateActionButtonIconSize,
    this.reserveText,
    this.style,
  }) : _tonal = false;

  const StateActionButton.tonal({
    super.key,
    required this.onPressed,
    required this.text,
    this.icon,
    this.iconSize = kStateActionButtonIconSize,
    this.reserveText,
    this.style,
  }) : _tonal = true;

  final VoidCallback? onPressed;
  final String text;
  final IconData? icon;

  /// Icon edge length, defaulting to [kStateActionButtonIconSize].
  ///
  /// Set here rather than via `ButtonStyle.iconSize`: the `Icon` in `build` passes
  /// `size`, overriding the `IconTheme` (`button_style_button.dart:553`).
  final double iconSize;

  /// Reserves label space for a longer status without changing button size.
  final String? reserveText;

  /// Overrides the default [styleOf]; used where callers need one shared spec.
  final ButtonStyle? style;
  final bool _tonal;

  /// Round at rest and squarer while pressed; [medium] is the 56dp size.
  static ButtonStyle styleOf(BuildContext context, {bool medium = false}) {
    return ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(64, medium ? 56 : 48)),
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: medium ? 24 : 16, vertical: 12),
      ),
      shape: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.pressed)
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(medium ? 12 : 8),
              )
            : const StadiumBorder(),
      ),
      animationDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 200),
    );
  }

  @override
  Widget build(BuildContext context) {
    final button = _tonal ? FilledButton.tonalIcon : FilledButton.icon;
    final label = Text(text, textAlign: TextAlign.center);
    return button(
      onPressed: onPressed,
      style: style ?? styleOf(context),
      icon: icon == null ? null : Icon(icon, size: iconSize),
      label: reserveText == null
          ? label
          : Stack(
              alignment: Alignment.center,
              children: [
                Visibility(
                  visible: false,
                  maintainSize: true,
                  maintainState: true,
                  maintainAnimation: true,
                  child: Text(reserveText!, textAlign: TextAlign.center),
                ),
                label,
              ],
            ),
    );
  }
}
