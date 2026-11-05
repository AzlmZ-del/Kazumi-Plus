/// 某一集的具体放送信息。
class AiringSlot {
  const AiringSlot({
    required this.episode,
    required this.airTime,
  });

  /// 集号（第几集）。
  final int episode;

  /// 放送时刻，已转换为设备本地时区。
  final DateTime airTime;

  Map<String, dynamic> toJson() => {
        'episode': episode,
        'airingAt': airTime.millisecondsSinceEpoch ~/ 1000,
      };

  static AiringSlot? fromJson(Map<String, dynamic> json) {
    final episode = json['episode'];
    final airingAt = json['airingAt'];
    if (episode is! int || airingAt is! int) return null;
    return AiringSlot(
      episode: episode,
      // airingAt 是 UTC 秒，必须 isUtc 再 toLocal，否则差一个时区。
      airTime: DateTime.fromMillisecondsSinceEpoch(airingAt * 1000, isUtc: true)
          .toLocal(),
    );
  }
}

/// 一部番的整季放送排期。
class SeasonSchedule {
  const SeasonSchedule({
    required this.anilistId,
    required this.slots,
  });

  final int anilistId;

  /// 整季排期，按集号升序。
  final List<AiringSlot> slots;

  bool get isEmpty => slots.isEmpty;

  /// 已播的最后一集；一集都没播时返回 null。
  AiringSlot? latestAired(DateTime now) {
    AiringSlot? result;
    for (final slot in slots) {
      if (slot.airTime.isAfter(now)) continue;
      if (result == null || slot.episode > result.episode) result = slot;
    }
    return result;
  }

  /// 待播的最近一集；全部播完时返回 null。
  AiringSlot? nextUpcoming(DateTime now) {
    AiringSlot? result;
    for (final slot in slots) {
      if (!slot.airTime.isAfter(now)) continue;
      if (result == null || slot.episode < result.episode) result = slot;
    }
    return result;
  }

  /// 取某个星期列上应显示的那一集，优先待播，否则退回已播。
  AiringSlot? slotForWeekday(int weekday, DateTime now) {
    AiringSlot? future;
    AiringSlot? past;
    for (final slot in slots) {
      if (slot.airTime.weekday != weekday) continue;
      if (slot.airTime.isAfter(now)) {
        if (future == null || slot.airTime.isBefore(future.airTime)) {
          future = slot;
        }
      } else {
        if (past == null || slot.airTime.isAfter(past.airTime)) {
          past = slot;
        }
      }
    }
    return future ?? past;
  }

  /// 整季的固定放送时刻：取各集时分的众数，避免个别集偏移导致跳动。
  ///
  /// 众数并列时退回最近一集的时刻。
  ({int hour, int minute}) typicalAirTime(DateTime now) {
    final counts = <String, int>{};
    final samples = <String, DateTime>{};
    for (final slot in slots) {
      final key =
          '${slot.airTime.hour.toString().padLeft(2, '0')}:'
          '${slot.airTime.minute.toString().padLeft(2, '0')}';
      counts[key] = (counts[key] ?? 0) + 1;
      samples[key] = slot.airTime;
    }

    String? bestKey;
    var bestCount = 0;
    var tied = false;
    counts.forEach((key, count) {
      if (count > bestCount) {
        bestCount = count;
        bestKey = key;
        tied = false;
      } else if (count == bestCount) {
        tied = true;
      }
    });

    if (bestKey == null) {
      final fallback = nextUpcoming(now) ?? latestAired(now);
      final t = fallback?.airTime ?? now;
      return (hour: t.hour, minute: t.minute);
    }

    if (tied) {
      // 并列时用最近一集的时刻，避免来回摇摆。
      final nearest = nextUpcoming(now) ?? latestAired(now);
      if (nearest != null) {
        return (hour: nearest.airTime.hour, minute: nearest.airTime.minute);
      }
    }

    final sample = samples[bestKey]!;
    return (hour: sample.hour, minute: sample.minute);
  }
}
