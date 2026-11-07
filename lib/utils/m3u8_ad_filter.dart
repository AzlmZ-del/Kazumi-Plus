import 'package:kazumi/utils/m3u8_parser.dart';

class M3u8AdFilter {
  /// 从媒体播放列表里过滤广告分片。
  /// 借助 discontinuity 分组模仿 FFmpeg 的 hls_ad_filter 行为。
  static List<M3u8Segment> filterAds(List<M3u8Segment> segments) {
    if (segments.isEmpty) return segments;

    // 按 discontinuityGroup 把分片分组。
    final groups = <int, List<M3u8Segment>>{};
    for (final seg in segments) {
      groups.putIfAbsent(seg.discontinuityGroup, () => []);
      groups[seg.discontinuityGroup]!.add(seg);
    }

    // 只有一组说明没检测到广告。
    if (groups.length <= 1) return segments;

    // 算出每组的总时长。
    final groupDurations = <int, double>{};
    for (final entry in groups.entries) {
      groupDurations[entry.key] = entry.value.fold<double>(
        0.0,
        (sum, seg) => sum + seg.duration,
      );
    }

    // 取最长的一组作为「正片」基准。
    double maxDuration = 0;
    for (final d in groupDurations.values) {
      if (d > maxDuration) maxDuration = d;
    }

    // 判定哪些组是广告。
    final adGroups = <int>{};
    final sortedKeys = groups.keys.toList()..sort();

    for (final groupId in sortedKeys) {
      final groupDuration = groupDurations[groupId]!;

      // 跳过正片那一组。
      if (groupDuration == maxDuration) continue;

      bool isAd = false;

      // 相对正片过短的组（不足 30%）也算广告。
      if (groupDuration < maxDuration * 0.3) {
        isAd = true;
      }

      // 位于首尾、且时长过短（< 30 秒）的组。
      if ((groupId == sortedKeys.first || groupId == sortedKeys.last) &&
          groupDuration < 30.0) {
        isAd = true;
      }

      // 极短的分片（< 10 秒）几乎肯定是广告。
      if (groupDuration < 10.0) {
        isAd = true;
      }

      if (isAd) {
        adGroups.add(groupId);
      }
    }

    if (adGroups.isEmpty) return segments;

    // 移除广告分片。
    return segments
        .where((seg) => !adGroups.contains(seg.discontinuityGroup))
        .toList();
  }

  /// 过滤后重新计算目标时长。
  static double calculateTargetDuration(List<M3u8Segment> segments) {
    if (segments.isEmpty) return 0;
    double maxSegDuration = 0;
    for (final seg in segments) {
      if (seg.duration > maxSegDuration) {
        maxSegDuration = seg.duration;
      }
    }
    return maxSegDuration;
  }
}
