import 'dart:async';

/// 按提交顺序逐个执行异步操作，同一时刻只跑一个。
class AsyncSerialQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final previous = _tail;
    final completer = Completer<T>();
    _tail = (() async {
      try {
        await previous;
      } catch (_) {}
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    })();
    return completer.future;
  }
}
