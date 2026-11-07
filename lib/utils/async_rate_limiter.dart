import 'dart:async';

/// 保证异步操作之间至少相隔一个最小时间间隔。
class AsyncRateLimiter {
  AsyncRateLimiter(this.period);

  final Duration period;
  DateTime _nextAllowedTime = DateTime.now();

  /// 等到下一个允许的时间点，并顺手把再下一个也占掉。
  Future<void> acquire() async {
    final now = DateTime.now();
    final scheduledTime =
        _nextAllowedTime.isAfter(now) ? _nextAllowedTime : now;
    _nextAllowedTime = scheduledTime.add(period);
    final waitDuration = scheduledTime.difference(now);
    if (waitDuration > Duration.zero) {
      await Future.delayed(waitDuration);
    }
  }

  /// 拿到限速时间片之后才执行 [action]。
  Future<T> run<T>(Future<T> Function() action) async {
    await acquire();
    return await action();
  }
}
