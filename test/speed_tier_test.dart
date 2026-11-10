import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/speed_tier.dart';

void main() {
  group('speedTierOf 边界', () {
    test('未开始或已取消（null）→ 无分级', () {
      expect(speedTierOf(null), isNull);
    });

    test('499ms → fast', () {
      expect(speedTierOf(499), SpeedTier.fast);
    });

    test('500ms → medium（下界含在中等）', () {
      expect(speedTierOf(500), SpeedTier.medium);
    });

    test('999ms → medium', () {
      expect(speedTierOf(999), SpeedTier.medium);
    });

    test('1000ms → slow（下界含在慢速）', () {
      expect(speedTierOf(1000), SpeedTier.slow);
    });
  });

  group('speedTierColor', () {
    const fallback = Color(0xFF123456);

    test('三级各取专属色，顺序与 SpeedTier 一致', () {
      expect(speedTierColor(SpeedTier.fast, fallback), kSpeedTierFastColor);
      expect(
          speedTierColor(SpeedTier.medium, fallback), kSpeedTierMediumColor);
      expect(speedTierColor(SpeedTier.slow, fallback), kSpeedTierSlowColor);
    });

    test('无分级时回落到传入的默认色', () {
      expect(speedTierColor(null, fallback), fallback);
    });
  });
}
