import 'package:flutter/material.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

/// [StateActionButton] 的图标边长统一值（18dp）。
///
/// 全局统一的一处开关：`StateActionButton` / `StateActionButton.tonal` 的
/// `iconSize` 默认值就是它，21 个带图标的调用点全部跟随。
///
/// 为什么不是 M3 默认的 20dp：Material Icons 的字形几乎写满方框（20dp 时
/// 实际墨迹 16.8~17.5dp），而 MiSans 汉字的墨迹高只有 `0.92 × fontSize`
/// （14sp → 12.9dp），并排时图标看着比文字块头大 30%。
const double kStateActionButtonIconSize = 18;

class StateIconBadge extends StatelessWidget {
  const StateIconBadge({
    super.key,
    required this.icon,
    required this.size,
    required this.iconSize,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final IconData icon;
  final double size;
  final double iconSize;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipPath(
      clipper: const _StateShapeClipper(),
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
  const _StateShapeClipper();

  static final _path = MaterialShapes.cookie4Sided.toPath();

  @override
  Path getClip(Size size) => _path.transform(
    Matrix4.diagonal3Values(size.width, size.height, 1).storage,
  );

  @override
  bool shouldReclip(_StateShapeClipper oldClipper) => false;
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

  /// 图标边长，默认 [kStateActionButtonIconSize]（18dp）。
  ///
  /// 需要「图标视觉上与 14sp 文字等高」时才有意义 —— 实测 MiSans 的汉字
  /// 墨迹高约 `0.92 × fontSize`（14sp → 12.9dp），而 Material Icons 的字形几乎写满
  /// 整个方框（20dp 时墨迹 16.8~17.5dp，比字大 30%），所以并排时图标显得块头压过文字。
  ///
  /// 不能靠 `ButtonStyle.iconSize` 覆盖：下面 `build` 里的 `Icon` 显式传了 `size`，
  /// 会盖掉 `AnimatedTheme` 下发的 `IconTheme`（`button_style_button.dart:553`）。
  final double iconSize;

  /// Reserves label space for a longer status without changing button size.
  final String? reserveText;

  /// 覆盖默认样式（`styleOf`）。传了就完全以这里为准，
  /// 用于「同步设置」这类需要统一规格的局部场景。
  final ButtonStyle? style;
  final bool _tonal;

  static ButtonStyle styleOf(BuildContext context) {
    return ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      ),
      shape: WidgetStateProperty.resolveWith(
        (states) => RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            states.contains(WidgetState.pressed) ? 16 : 28,
          ),
        ),
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
