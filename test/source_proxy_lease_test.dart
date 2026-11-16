import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/source_network_route.dart';
import 'package:kazumi/services/network/source_proxy_lease.dart';

void main() {
  const direct = SourceNetworkRoute.direct();
  const system = SourceNetworkRoute.system();

  test(
    'leases serialize the complete page lifecycle and restore before handoff',
    () async {
      final events = <String>[];
      final manager = SourceProxyLeaseManager(
        apply: (route) async => events.add('apply:${route.mode.name}'),
        restore: () async => events.add('restore'),
      );
      final first = await manager.acquire(direct);
      var secondAcquired = false;
      final secondFuture = manager.acquire(system).then((lease) {
        secondAcquired = true;
        return lease;
      });
      await Future<void>.delayed(Duration.zero);
      expect(secondAcquired, isFalse);
      expect(events, ['apply:direct']);
      await first.release();
      final second = await secondFuture;
      expect(events, ['apply:direct', 'restore', 'apply:system']);
      await second.release();
      expect(events.last, 'restore');
    },
  );

  test(
    'release is idempotent and callers await the same restoration',
    () async {
      var restored = 0;
      final manager = SourceProxyLeaseManager(
        apply: (_) async {},
        restore: () async => restored++,
      );
      final lease = await manager.acquire(direct);
      final first = lease.release();
      expect(identical(first, lease.release()), isTrue);
      await first;
      expect(restored, 1);
    },
  );

  test(
    'a cancelled queued lease does not mutate the active page proxy',
    () async {
      final events = <String>[];
      final manager = SourceProxyLeaseManager(
        apply: (route) async => events.add(route.mode.name),
        restore: () async => events.add('restore'),
      );
      final first = await manager.acquire(direct);
      final cancelled = Completer<void>();
      final pending = manager.acquire(system, cancelled: cancelled.future);
      final expectation = expectLater(
        pending,
        throwsA(isA<SourceProxyLeaseCancelled>()),
      );
      cancelled.complete();
      await expectation;
      expect(events, ['direct']);
      final thirdFuture = manager.acquire(direct);
      await first.release();
      final third = await thirdFuture;
      expect(events, ['direct']);
      await third.release();
      expect(events, ['direct', 'restore']);
    },
  );

  test(
    'cancellation while applying restores before allowing the next lease',
    () async {
      final applying = Completer<void>();
      final started = Completer<void>();
      final events = <String>[];
      final manager = SourceProxyLeaseManager(
        apply: (route) async {
          events.add(route.mode.name);
          if (route == direct) {
            started.complete();
            await applying.future;
          }
        },
        restore: () async => events.add('restore'),
      );
      final cancelled = Completer<void>();
      final pending = manager.acquire(direct, cancelled: cancelled.future);
      final expectation = expectLater(
        pending,
        throwsA(isA<SourceProxyLeaseCancelled>()),
      );
      await started.future;
      cancelled.complete();
      await expectation;
      final nextFuture = manager.acquire(system);
      applying.complete();
      final next = await nextFuture;
      expect(events, ['direct', 'restore', 'system']);
      await next.release();
    },
  );

  test(
    'failed proxy application restores and does not poison the queue',
    () async {
      var attempts = 0;
      var restored = 0;
      final manager = SourceProxyLeaseManager(
        apply: (_) async {
          if (attempts++ == 0) throw StateError('apply failed');
        },
        restore: () async => restored++,
      );
      await expectLater(manager.acquire(direct), throwsStateError);
      expect(restored, 1);
      final next = await manager.acquire(system);
      await next.release();
      expect(restored, 2);
    },
  );

  test('restoration failure is visible but releases queue ownership', () async {
    var attempts = 0;
    final manager = SourceProxyLeaseManager(
      apply: (_) async {},
      restore: () async {
        if (attempts++ == 0) throw StateError('restore failed');
      },
    );
    final first = await manager.acquire(direct);
    final nextFuture = manager.acquire(system);
    await expectLater(first.release(), throwsStateError);
    final next = await nextFuture;
    await next.release();
    expect(attempts, 2);
  });

  test('pre-cancelled same-route acquisition never adds a holder', () async {
    var applied = 0;
    var restored = 0;
    final manager = SourceProxyLeaseManager(
      apply: (_) async {
        applied++;
      },
      restore: () async {
        restored++;
      },
    );
    final first = await manager.acquire(system);
    final cancelled = Completer<void>()..complete();
    await expectLater(
      manager.acquire(system, cancelled: cancelled.future),
      throwsA(isA<SourceProxyLeaseCancelled>()),
    );
    await first.release();
    expect(applied, 1);
    expect(restored, 1);
  });

  test('a new route cannot apply while restoration is pending', () async {
    final restoring = Completer<void>();
    final started = Completer<void>();
    final events = <String>[];
    var firstRestore = true;
    final manager = SourceProxyLeaseManager(
      apply: (route) async {
        events.add(route.mode.name);
      },
      restore: () async {
        if (firstRestore) {
          firstRestore = false;
          started.complete();
          await restoring.future;
        }
        events.add('restore');
      },
    );
    final first = await manager.acquire(system);
    final release = first.release();
    await started.future;
    var acquired = false;
    final next = manager.acquire(direct).then((lease) {
      acquired = true;
      return lease;
    });
    await Future<void>.delayed(Duration.zero);
    expect(acquired, isFalse);
    expect(events, ['system']);
    restoring.complete();
    await release;
    final second = await next;
    expect(events, ['system', 'restore', 'direct']);
    await second.release();
  });

  test('same route pages share one application and restore once', () async {
    final events = <String>[];
    final manager = SourceProxyLeaseManager(
      apply: (route) async => events.add('apply:${route.mode.name}'),
      restore: () async => events.add('restore'),
    );
    final first = await manager.acquire(system);
    final second = await manager.acquire(system);
    expect(events, ['apply:system']);
    var directAcquired = false;
    final directFuture = manager.acquire(direct).then((lease) {
      directAcquired = true;
      return lease;
    });
    await first.release();
    await Future<void>.delayed(Duration.zero);
    expect(directAcquired, isFalse);
    expect(events, ['apply:system']);
    await second.release();
    final third = await directFuture;
    expect(events, ['apply:system', 'restore', 'apply:direct']);
    await third.release();
  });

  test(
    'a different route waits even if a same route request queues behind it',
    () async {
      final events = <String>[];
      final manager = SourceProxyLeaseManager(
        apply: (route) async => events.add(route.mode.name),
        restore: () async => events.add('restore'),
      );
      final first = await manager.acquire(system);
      final directFuture = manager.acquire(direct);
      var lateSystem = false;
      final systemFuture = manager.acquire(system).then((lease) {
        lateSystem = true;
        return lease;
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        lateSystem,
        isFalse,
        reason: 'FIFO keeps the direct page from starving',
      );
      await first.release();
      final second = await directFuture;
      await second.release();
      final third = await systemFuture;
      expect(events, ['system', 'restore', 'direct', 'restore', 'system']);
      await third.release();
    },
  );
}
