import 'dart:async';
import 'dart:collection';

import 'package:kazumi/services/network/source_network_route.dart';
import 'package:kazumi/utils/async_serial_queue.dart';

class SourceProxyLeaseCancelled implements Exception {
  const SourceProxyLeaseCancelled();
}

class SourceProxyLease {
  SourceProxyLease(this._restore);

  final Future<void> Function() _restore;
  Future<void>? _released;

  Future<void> release() => _released ??= Future.sync(_restore);
}

class _PendingLease {
  _PendingLease(this.route);

  final SourceNetworkRoute route;
  final completer = Completer<SourceProxyLease>();
  bool get done => completer.isCompleted;
}

/// 同一出口可并行持有；不同出口按队列等待全部页面释放后再切换。
class SourceProxyLeaseManager {
  SourceProxyLeaseManager({required this.apply, required this.restore});

  final Future<void> Function(SourceNetworkRoute route) apply;
  final Future<void> Function() restore;
  final _queue = Queue<_PendingLease>();
  final _operations = AsyncSerialQueue();
  SourceNetworkRoute? _route;
  int _holders = 0;

  Future<SourceProxyLease> acquire(
    SourceNetworkRoute route, {
    Future<void>? cancelled,
  }) {
    final pending = _PendingLease(route);
    _queue.add(pending);
    cancelled?.then((_) {
      if (pending.done) return;
      pending.completer.completeError(const SourceProxyLeaseCancelled());
      _queue.remove(pending);
      _pump();
    });
    _pump();
    return pending.completer.future;
  }

  // 应用和恢复通过同一队列执行，不能在 await restore 期间插入一次 apply。
  void _pump() => unawaited(_operations.run(_drain));

  Future<void> _drain() async {
    while (_queue.isNotEmpty) {
      final next = _queue.first;
      if (next.done) {
        _queue.removeFirst();
        continue;
      }
      if (_holders > 0) {
        if (next.route != _route) return;
        _queue.removeFirst();
        _grant(next);
        continue;
      }
      _queue.removeFirst();
      try {
        await apply(next.route);
      } catch (error, stackTrace) {
        await _restoreQuietly();
        if (!next.done) next.completer.completeError(error, stackTrace);
        continue;
      }
      if (next.done) {
        await _restoreQuietly();
        continue;
      }
      _route = next.route;
      _grant(next);
    }
  }

  void _grant(_PendingLease pending) {
    _holders++;
    pending.completer.complete(SourceProxyLease(_release));
  }

  Future<void> _release() => _operations.run(() async {
    _holders--;
    if (_holders > 0) return;
    try {
      await restore();
    } finally {
      _route = null;
      _pump();
    }
  });

  Future<void> _restoreQuietly() async {
    try {
      await restore();
    } catch (_) {}
    _route = null;
  }
}
