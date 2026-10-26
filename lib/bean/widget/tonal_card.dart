import 'package:flutter/material.dart';

const double tonalCardRadius = 24;

/// 深色主题下每档 `elevation` 对应的描边不透明度。
///
/// 标定值：`elevation = 1.5` 时描边 10% 白。深色没有投影可画（黑底上的
/// 黑影是隐形的），全靠这圈描边表达「浮起」。
const double _darkOutlineAlphaPerLevel = 0.10 / 1.5;

/// 亮色主题下每档 `elevation` 对应的描边不透明度。
///
/// 标定值：`elevation = 1.5` 时 `outlineVariant` 描边 30%。
///
/// 亮色为什么不靠投影：卡片用的是 `surfaceContainerLow`（亮色 tone 96），
/// 比页面背景 `surface`（tone 98）**只深 6 个灰阶**，而且是「更暗」不是
/// 「更亮」；投影还会被高斯模糊摊薄 —— `blurRadius` 13 时直边处只剩约
/// 3.5% 不透明度，落在卡片上只差 3 个灰阶，肉眼等于没有。
/// 30% 的 `outlineVariant`（亮色 tone 80 ≈ `#C6C6C6`）能拉开约 14 个灰阶，
/// 而且是 1px 硬边、不模糊，边界立刻锐利。40% 试过偏重，30% 更含蓄。
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

  /// 立体感的强度，默认 0 = 纯色块（靠 `surfaceContainerLow` 的色调分层）。
  ///
  /// 只有确实需要「卡片浮起来」的页面才传，**别改默认值** —— 全项目有 19 处
  /// 在用这个组件，默认值一动就是全局视觉变化。
  ///
  /// 亮色与深色都用一圈 1px 描边表达「浮起」，只是描边色不同：
  /// 亮色用 `outlineVariant`，深色（含 OLED 纯黑）用极淡的白光。
  /// 不用投影是因为亮色下投影被模糊摊薄后几乎不可见，见上方常量注释。
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
      // 统一走 `shape`：`Material` 里 `shape` 与 `borderRadius` 互斥
      // （`material.dart:209` 的断言），二选一才不会在断言里炸。
      // 不浮起时用 `BorderSide.none`，零宽描边，不占布局。
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: lifted ? BorderSide(color: outlineColor) : BorderSide.none,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
