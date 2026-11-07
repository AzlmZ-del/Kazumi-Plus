import 'package:kazumi/utils/async_serial_queue.dart';

/// 把各数据层与同步对历史 Hive box 的写操作串行化。
class HistoryStorageCoordinator {
  HistoryStorageCoordinator._();

  static final HistoryStorageCoordinator _instance =
      HistoryStorageCoordinator._();

  factory HistoryStorageCoordinator() => _instance;

  final AsyncSerialQueue _writes = AsyncSerialQueue();

  Future<T> run<T>(Future<T> Function() action) => _writes.run(action);
}
