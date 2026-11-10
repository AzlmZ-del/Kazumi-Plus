import 'package:flutter/material.dart';

/// 请求耗时分级：< 500ms 快、500–1000ms 中、≥ 1000ms 慢。
///
/// 两处耗时展示（播放来源弹窗、插件测试页）共用同一套阈值与配色，
/// 避免两边各写一份后阈值漂移。
enum SpeedTier { fast, medium, slow }

/// 三个分级共用的配色，顺序与 [SpeedTier] 一致。
const kSpeedTierFastColor = Color(0xFF2E7D32);
const kSpeedTierMediumColor = Color(0xFFE65100);
const kSpeedTierSlowColor = Color(0xFFC62828);

/// 按耗时毫秒分级；[ms] 为空（未开始 / 被取消）时返回 null，调用方回落到默认色。
SpeedTier? speedTierOf(int? ms) {
  if (ms == null) return null;
  if (ms < 500) return SpeedTier.fast;
  if (ms < 1000) return SpeedTier.medium;
  return SpeedTier.slow;
}

/// 分级取色；无分级时回落到 [fallback]。
Color speedTierColor(SpeedTier? tier, Color fallback) => switch (tier) {
      SpeedTier.fast => kSpeedTierFastColor,
      SpeedTier.medium => kSpeedTierMediumColor,
      SpeedTier.slow => kSpeedTierSlowColor,
      null => fallback,
    };
