import 'dart:async';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/account_install_persistence_port.dart';
import 'package:PiliPlus/services/native_accounts/account_write_back_coordinator.dart';
import 'package:PiliPlus/services/native_accounts/native_account_live_memory_capture.dart';
import 'package:PiliPlus/services/native_accounts/native_account_snapshot_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'account_test_storage.dart';

// Test-local session ownership/acquisition harness for the bounded S1
// prerequisite slice of the frozen-revision composition plan. It exercises
// the REAL coordinator, capture and restore gates only: it is not a
// production session API, not a lease and not an authorization. Every
// controlled future, grant, checkpoint and port reaches terminal cleanup in
// `finally`, including failed assertion paths; gated waits attach immediate
// handled outcome observers or a phase-or-terminal helper so an early
// terminal error fails promptly with its exact identity instead of hanging
// or skipping the ownership release. No timers and no elapsed-time
// noncompletion oracles are used.
LoginAccount _account(int mid) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'csrf-$mid',
    'SESSDATA': 'session-$mid',
  }),
  'access-$mid',
  'refresh-$mid',
)..activated = true;

/// Cooperative abort signal for a pending acquisition. Dart futures cannot be
/// cancelled: the signal is only checked after the coordinator's real await
/// boundary returns; it never detaches, wraps or replaces the coordinator
/// future.
final class _SessionAbortSignal {
  final Completer<void> _aborted = Completer<void>();

  bool get isAborted => _aborted.isCompleted;

  void abort() {
    if (!_aborted.isCompleted) {
      _aborted.complete();
    }
  }
}

/// Typed test-local abort result (deliberate marker, not a production error).
final class _SessionAbort implements Exception {
  const _SessionAbort();
}

/// Exclusive ownership handle for one real maintenance token. [end] is
/// exactly-once and idempotent, only resumes admissions, and never clears a
/// prior freeze, a permanent close, or any journal/Native state.
final class _SessionLease {
  _SessionLease(this._barrier);

  final AccountWriteBackMaintenance _barrier;
  bool _ended = false;

  bool get isEnded => _ended;

  void end() {
    if (_ended) return;
    _ended = true;
    _barrier.end(permanent: false);
  }
}

/// Test-local acquisition/session helper. It awaits the real
/// [AccountWriteBackCoordinator.beginMaintenance] to its terminal grant: a
/// caller that discards the handle could never release the claimed
/// exclusivity (there is no public lever), so the helper must retain it,
/// await it, and end it exactly once on every path.
final class _SessionOwnershipHarness {
  _SessionOwnershipHarness(this.coordinator);

  final AccountWriteBackCoordinator coordinator;

  /// Awaits the terminal grant. A closed coordinator has no token and
  /// surfaces [StateError]. If [abort] fired while the grant was pending,
  /// ownership is still obtained first, ended exactly once, and only then
  /// [_SessionAbort] is thrown (never instant cancellation of the real
  /// future).
  Future<_SessionLease> acquire({_SessionAbortSignal? abort}) async {
    final barrier = await coordinator.beginMaintenance();
    if (barrier == null) {
      throw StateError('session owner is closed');
    }
    final lease = _SessionLease(barrier);
    if (abort != null && abort.isAborted) {
      lease.end();
      throw const _SessionAbort();
    }
    return lease;
  }

  /// Runs [body] under an exclusively held lease; the token is ended exactly
  /// once on success, ordinary throw and early body failure.
  Future<T> withSession<T>(
    Future<T> Function(_SessionLease lease) body, {
    _SessionAbortSignal? abort,
  }) async {
    final lease = await acquire(abort: abort);
    try {
      return await body(lease);
    } finally {
      lease.end();
    }
  }
}

/// Real Hive writes behind a controllable seam: the public captured-restore
/// window stays open while stamped reads are performed against it.
final class _GatedRestorePort implements AccountInstallPersistencePort {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> writeLegacyInstall(
    Box<LoginAccount> box,
    String key,
    LoginAccount value,
  ) => accountInstallPersistencePort.writeLegacyInstall(box, key, value);

  @override
  Future<void> writeLegacyImport(
    Box<LoginAccount> box,
    Map<String, LoginAccount> values,
  ) async {
    if (!started.isCompleted) {
      started.complete();
    }
    await release.future;
    await accountInstallPersistencePort.writeLegacyImport(box, values);
  }
}

/// Deterministic empty-target fixture: delete/reset only, with no `clear()`'s
/// fire-and-forget buvid activation. All actual Hive/jar deletes are awaited.
Future<void> _prepareEmptyTarget() async {
  final anonymous = AnonymousAccount();
  for (final purpose in AccountType.values) {
    Accounts.selectTemporarily(purpose, anonymous);
  }
  for (final account in Accounts.account.values.toList()) {
    await account.delete();
  }
  await anonymous.delete();
  AnonymousAccount().activated = true;
}

/// Attaches an immediate handled terminal observer to [future]: an error can
/// no longer surface as an unhandled asynchronous error while the test still
/// performs other assertions, and awaiting the returned future drains the
/// SAME [future] to its terminal outcome without throwing. The success path
/// still awaits the original future directly so a terminal error is never
/// reported as success.
Future<void> _observeTerminal<T>(Future<T> future) {
  return future.then<void>((_) {}, onError: (Object _) {});
}

/// Completes normally when the gated [started] phase opens. If [terminal]
/// completes first, fails promptly with the SAME public error object (or a
/// phase violation for an early success) instead of waiting on a phase that
/// can never start. Observes real future completion only: no timers, sleeps
/// or fabricated phase completion.
Future<void> _awaitStartedOrTerminal({
  required Future<void> started,
  required Future<void> terminal,
}) async {
  final outcome = Completer<int>();
  final failure = Completer<Object>();
  final trace = Completer<StackTrace>();
  started.then((_) {
    if (!outcome.isCompleted) {
      outcome.complete(0);
    }
  });
  terminal.then(
    (_) {
      if (!outcome.isCompleted) {
        outcome.complete(1);
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!outcome.isCompleted) {
        failure.complete(error);
        trace.complete(stackTrace);
        outcome.complete(2);
      }
    },
  );
  final kind = await outcome.future;
  if (kind == 0) return;
  if (kind == 1) {
    throw StateError('terminal completion before the gated phase started');
  }
  Error.throwWithStackTrace(await failure.future, await trace.future);
}

void main() {
  late AccountTestStorage storage;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });
  setUp(() => storage.reset());
  tearDownAll(() => storage.close());

  test('abort while acquisition is pending ends the granted token before the typed abort', () async {
    final coordinator = AccountWriteBackCoordinator();
    final harness = _SessionOwnershipHarness(coordinator);
    final admitted = coordinator.tryAdmit()!;
    final signal = _SessionAbortSignal();
    final pending = harness.acquire(abort: signal);
    final rejected = expectLater(pending, throwsA(isA<_SessionAbort>()));
    try {
      // Exclusivity is claimed synchronously, before the drain completes.
      expect(coordinator.isMaintenanceActive, true);
      expect(coordinator.tryAdmit(), isNull);
    } finally {
      // Failure-path safety: the abort fires while the acquisition is still
      // pending, the drain is released, and the helper ends the granted
      // token exactly once before the typed abort surfaces.
      signal.abort();
      admitted.release();
      await rejected;
    }
    expect(coordinator.isMaintenanceActive, false);
    expect(coordinator.admittedCount, 0);
    expect(coordinator.liveOperationCount, 0);
    // Acquire-after-abort stays available: the aborted grant was cleaned up.
    final lease = await harness.acquire();
    try {
      expect(coordinator.tryAdmit(), isNull);
    } finally {
      lease.end();
    }
    final after = coordinator.tryAdmit();
    expect(after, isNotNull);
    after!.release();
  });

  test('harness acquisition states stay explicit for a closed owner and a pre-fired abort', () async {
    final closed = AccountWriteBackCoordinator();
    final closedHarness = _SessionOwnershipHarness(closed);
    final closedToken = await closed.beginMaintenance();
    try {
      expect(closedToken, isNotNull);
    } finally {
      closedToken?.end(permanent: true);
    }
    expect(closed.isClosed, true);
    await expectLater(closedHarness.acquire(), throwsA(isA<StateError>()));
    expect(closed.isMaintenanceActive, false);

    final coordinator = AccountWriteBackCoordinator();
    final harness = _SessionOwnershipHarness(coordinator);
    final signal = _SessionAbortSignal()..abort();
    await expectLater(harness.acquire(abort: signal), throwsA(isA<_SessionAbort>()));
    // Ownership was obtained first, ended exactly once, and only then the
    // abort surfaced; no real future was cancelled.
    expect(coordinator.isMaintenanceActive, false);
    final after = coordinator.tryAdmit();
    expect(after, isNotNull);
    after!.release();
  });

  test('a withheld first owner blocks admissions while a retained second acquisition waits, then recovers', () async {
    final coordinator = AccountWriteBackCoordinator();
    final admitted = coordinator.tryAdmit()!;
    // The first acquisition claims exclusivity synchronously; its grant is
    // withheld until the admitted chain drains. Both futures are retained:
    // discarding them would leave the claimed maintenance unreleasable.
    final first = coordinator.beginMaintenance();
    var secondGranted = false;
    final second = coordinator.beginMaintenance();
    final secondObserver = second.then((token) {
      secondGranted = token != null;
    });
    try {
      // Explicit controlled boundary: event-loop turns only, no timers.
      await Future<void>.value();
      expect(coordinator.isMaintenanceActive, true);
      expect(coordinator.admittedCount, 1);
      expect(coordinator.tryAdmit(), isNull);
      expect(secondGranted, false);

      admitted.release();
      final firstToken = await first;
      expect(firstToken, isNotNull);
      expect(coordinator.tryAdmit(), isNull);
      firstToken?.end(permanent: false);

      final secondToken = await second;
      await secondObserver;
      expect(secondGranted, true);
      expect(secondToken, isNotNull);
      expect(coordinator.tryAdmit(), isNull);
      secondToken?.end(permanent: false);
    } finally {
      // Failure-path safety: the retained handles always reach terminal
      // cleanup and exactly-once end, even if an assertion above failed.
      admitted.release();
      final firstToken = await first;
      firstToken?.end(permanent: false);
      final secondToken = await second;
      secondToken?.end(permanent: false);
      await secondObserver;
    }
    expect(coordinator.isMaintenanceActive, false);
    expect(coordinator.admittedCount, 0);
    expect(coordinator.isClosed, false);
    final after = coordinator.tryAdmit();
    expect(after, isNotNull);
    after!.release();
  });

  test('a successful session ends once and the queued second acquirer proceeds', () async {
    final coordinator = AccountWriteBackCoordinator();
    final harness = _SessionOwnershipHarness(coordinator);
    Future<_SessionLease>? second;
    try {
      // The ownership cleanup scope covers the session await itself: if the
      // body or an early verification fails, withSession still ends FIRST
      // and the granted SECOND is ended below instead of leaking.
      await harness.withSession((_) {
        // Registers the second acquirer's waiter synchronously, before any
        // other expectation, so failure paths always retain the handle.
        second = harness.acquire();
        expect(coordinator.isMaintenanceActive, true);
        return Future<void>.value();
      });
      // Ownership transferred to the queued acquirer without reopening it.
      expect(coordinator.isMaintenanceActive, true);
      expect(coordinator.tryAdmit(), isNull);
      final secondLease = await second!;
      expect(secondLease.isEnded, false);
      expect(coordinator.tryAdmit(), isNull);
      secondLease.end();
      expect(secondLease.isEnded, true);
    } finally {
      // Failure-path safety: the queued grant still reaches terminal cleanup.
      final queued = second;
      if (queued != null) {
        final secondLease = await queued;
        secondLease.end();
      }
    }
    expect(coordinator.isMaintenanceActive, false);
    final after = coordinator.tryAdmit();
    expect(after, isNotNull);
    after!.release();
  });

  test('a throwing session preserves the failure identity and the queued second acquirer proceeds', () async {
    final coordinator = AccountWriteBackCoordinator();
    final harness = _SessionOwnershipHarness(coordinator);
    final failure = StateError('synthetic session failure');
    Future<_SessionLease>? second;
    final session = harness.withSession((_) {
      second = harness.acquire();
      return Future<void>.error(failure);
    });
    try {
      await expectLater(session, throwsA(same(failure)));
      final secondLease = await second!;
      expect(coordinator.isMaintenanceActive, true);
      expect(coordinator.tryAdmit(), isNull);
      secondLease.end();
    } finally {
      // Failure-path safety: the queued grant still reaches terminal cleanup.
      final queued = second;
      if (queued != null) {
        final secondLease = await queued;
        secondLease.end();
      }
    }
    expect(coordinator.isMaintenanceActive, false);
    final after = coordinator.tryAdmit();
    expect(after, isNotNull);
    after!.release();
  });

  test('an early callback failure after the second registration still ends the queued grant', () async {
    final coordinator = AccountWriteBackCoordinator();
    final harness = _SessionOwnershipHarness(coordinator);
    final failure = StateError('synthetic early callback failure');
    Future<_SessionLease>? second;
    final session = harness.withSession((_) {
      second = harness.acquire();
      throw failure;
    });
    try {
      // The exact original failure identity must surface.
      await expectLater(session, throwsA(same(failure)));
      // withSession ended FIRST before the session settled, so the queued
      // SECOND was granted; it must still reach terminal cleanup here.
      final secondLease = await second!;
      expect(coordinator.isMaintenanceActive, true);
      secondLease.end();
    } finally {
      // Failure-path safety: the queued grant still reaches terminal cleanup.
      final queued = second;
      if (queued != null) {
        final secondLease = await queued;
        secondLease.end();
      }
    }
    expect(coordinator.isMaintenanceActive, false);
    expect(coordinator.admittedCount, 0);
    final after = coordinator.tryAdmit();
    expect(after, isNotNull);
    after!.release();
  });

  test('a failing verification after the second registration still ends the queued grant', () async {
    final coordinator = AccountWriteBackCoordinator();
    final harness = _SessionOwnershipHarness(coordinator);
    Future<_SessionLease>? second;
    final session = harness.withSession((_) {
      second = harness.acquire();
      // Controlled negative: this verification is deliberately false while
      // the first session holds the exclusive barrier, forcing the
      // formerly-skipped queued-grant cleanup path.
      expect(coordinator.tryAdmit(), isNotNull);
      return Future<void>.value();
    });
    try {
      await expectLater(session, throwsA(isA<TestFailure>()));
      final secondLease = await second!;
      expect(coordinator.isMaintenanceActive, true);
      secondLease.end();
    } finally {
      // Failure-path safety: the queued grant still reaches terminal cleanup.
      final queued = second;
      if (queued != null) {
        final secondLease = await queued;
        secondLease.end();
      }
    }
    expect(coordinator.isMaintenanceActive, false);
    expect(coordinator.admittedCount, 0);
    final after = coordinator.tryAdmit();
    expect(after, isNotNull);
    after!.release();
  });

  test('session cleanup never clears a terminal freeze on the success or throw path', () async {
    final coordinator = AccountWriteBackCoordinator();
    final harness = _SessionOwnershipHarness(coordinator);
    await coordinator.freeze();
    await harness.withSession((_) {
      expect(coordinator.isMaintenanceActive, true);
      expect(coordinator.tryAdmit(), isNull);
      return Future<void>.value();
    });
    expect(coordinator.isFrozen, true);
    expect(coordinator.isMaintenanceActive, false);
    expect(coordinator.tryAdmit(), isNull);
    final failure = StateError('synthetic frozen session failure');
    await expectLater(
      harness.withSession((_) {
        return Future<void>.error(failure);
      }),
      throwsA(same(failure)),
    );
    expect(coordinator.isFrozen, true);
    expect(coordinator.isMaintenanceActive, false);
    expect(coordinator.tryAdmit(), isNull);
  });

  test('a held session rejects real admitted mutations with zero effect while an optimistic capture completes', () async {
    final coordinator = AccountWriteBackCoordinator();
    final harness = _SessionOwnershipHarness(coordinator);
    await Accounts.installCredentials(_account(940000), coordinator: coordinator);
    final lease = await harness.acquire();
    final gate = Completer<void>();
    final captured = NativeAccountLiveMemoryCaptureService(checkpoint: () => gate.future).capture();
    // Immediate handled observer: a terminal capture error cannot surface as
    // an unhandled asynchronous error while the writer assertions run.
    final capturedObserver = _observeTerminal(captured);
    final frozen = isA<StateError>().having((error) => error.message, 'message', 'Account write-back is frozen');
    try {
      final revision = Accounts.requestRevision;
      // Real production mutations through the same injected coordinator.
      await expectLater(
        Accounts.installCredentials(_account(940001), coordinator: coordinator),
        throwsA(frozen),
      );
      expect(
        () => Accounts.selectTemporarily(AccountType.video, _account(940002), coordinator: coordinator),
        throwsA(frozen),
      );
      expect(Accounts.account.get('940001'), isNull);
      expect(Accounts.installedAccounts().length, 1);
      expect(identical(Accounts.get(AccountType.video), AnonymousAccount()), true);
      expect(Accounts.requestRevision, revision);
      gate.complete();
      final value = await captured;
      expect((value['storedOrder'] as List).length, 1);
    } finally {
      // Failure-path safety: the checkpoint is always released, the same real
      // capture is awaited to its terminal outcome, and the token ends
      // independently of that outcome.
      if (!gate.isCompleted) {
        gate.complete();
      }
      try {
        await captured;
      } finally {
        lease.end();
      }
      await capturedObserver;
    }
    // Only coordinator-covered writers were fenced; the capture itself was
    // never admission-gated and verified successfully.
    expect(coordinator.isMaintenanceActive, false);
    final after = coordinator.tryAdmit();
    expect(after, isNotNull);
    after!.release();
  });

  test('a terminal capture checkpoint failure while maintenance is held still ends the session lease', () async {
    final coordinator = AccountWriteBackCoordinator();
    final harness = _SessionOwnershipHarness(coordinator);
    await Accounts.installCredentials(_account(940030), coordinator: coordinator);
    final lease = await harness.acquire();
    final checkpointFailure = StateError('synthetic capture checkpoint failure');
    final captured = NativeAccountLiveMemoryCaptureService(
      checkpoint: () => Future<void>.error(checkpointFailure),
    ).capture();
    // Immediate handled observer before the held session awaits the capture.
    final capturedObserver = _observeTerminal(captured);
    try {
      // The real capture is terminally failed while the session still owns
      // the barrier; the old finally skipped lease.end exactly on this await.
      await expectLater(captured, throwsA(same(checkpointFailure)));
      expect(coordinator.tryAdmit(), isNull);
    } finally {
      // Failure-path safety: drain the already-asserted terminal capture and
      // end the token independently of that outcome.
      try {
        await capturedObserver;
      } finally {
        lease.end();
      }
    }
    expect(coordinator.isMaintenanceActive, false);
    expect(coordinator.admittedCount, 0);
    final after = coordinator.tryAdmit();
    expect(after, isNotNull);
    after!.release();
  });

  test('an admitted install inside the checkpoint window rejects the optimistic capture', () async {
    final coordinator = AccountWriteBackCoordinator();
    await Accounts.installCredentials(_account(940010), coordinator: coordinator);
    final candidate = Accounts.captureLiveMemoryShadow();
    final revision = Accounts.requestRevision;
    final gate = Completer<void>();
    final pending = NativeAccountLiveMemoryCaptureService(checkpoint: () => gate.future).capture();
    final rejected = expectLater(
      pending,
      throwsA(isA<AccountLiveMemoryShadowException>().having((error) => error.code, 'code', 'snapshotChanged')),
    );
    try {
      await Accounts.installCredentials(_account(940011), coordinator: coordinator);
      expect(coordinator.isFrozen, false);
      // Independent source-state oracles, not the capture's own comparison.
      expect(Accounts.account.get('940011'), isNotNull);
      expect(Accounts.installedAccounts().length, 2);
      expect(Accounts.requestRevision, greaterThan(revision));
      expect((candidate.value['storedOrder'] as List).length, 1);
    } finally {
      if (!gate.isCompleted) {
        gate.complete();
      }
      await rejected;
    }
  });

  test('an admitted selection change inside the checkpoint window rejects the optimistic capture', () async {
    final coordinator = AccountWriteBackCoordinator();
    final account = _account(940012);
    await Accounts.installCredentials(account, coordinator: coordinator);
    final candidate = Accounts.captureLiveMemoryShadow();
    final gate = Completer<void>();
    final pending = NativeAccountLiveMemoryCaptureService(checkpoint: () => gate.future).capture();
    final rejected = expectLater(
      pending,
      throwsA(isA<AccountLiveMemoryShadowException>().having((error) => error.code, 'code', 'snapshotChanged')),
    );
    try {
      Accounts.selectTemporarily(AccountType.video, account, coordinator: coordinator);
      // Independent selection oracle versus the captured pre-image.
      expect(identical(Accounts.get(AccountType.video), account), true);
      expect((candidate.value['selections'] as List)[AccountType.video.index], 0);
    } finally {
      if (!gate.isCompleted) {
        gate.complete();
      }
      await rejected;
    }
  });

  test('the public captured-restore window maps capture to busy, the snapshot service to snapshotChanged, with zero read-side effects', () async {
    await _prepareEmptyTarget();
    AnonymousAccount().type.clear();
    final anonymous = AnonymousAccount();
    final port = _GatedRestorePort();
    final revision = Accounts.requestRevision;
    final restore = Accounts.restoreEmptyCaptured(
      accounts: [_account(940020)],
      ownerOrdinals: [1],
      anonymousJar: anonymous.cookieJar,
      anonymousPurposes: Set<AccountType>.of(anonymous.type),
      anonymousActivated: true,
      selections: [0, 1, 0, 0],
      persistencePort: port,
    );
    // Immediate handled observer: the restore's terminal error cannot surface
    // as an unhandled asynchronous error while the window reads run.
    final restoreObserver = _observeTerminal(restore);
    try {
      // Phase-or-terminal observation: a pre-port terminal rejection fails
      // promptly with its exact public error instead of waiting on a phase
      // that can never start.
      await _awaitStartedOrTerminal(started: port.started.future, terminal: restore);
      // The captured-restore window is open. Capture fails closed with its
      // own typed busy error; the snapshot service has a different mapping.
      expect(
        Accounts.captureLiveMemoryShadow,
        throwsA(isA<AccountLiveMemoryShadowException>().having((error) => error.code, 'code', 'busy')),
      );
      await expectLater(
        NativeAccountLiveMemoryCaptureService().capture(),
        throwsA(isA<AccountLiveMemoryShadowException>().having((error) => error.code, 'code', 'busy')),
      );
      await expectLater(
        NativeAccountSnapshotService().selectionSnapshot(),
        throwsA(isA<NativeAccountSnapshotException>().having((error) => error.code, 'code', 'snapshotChanged')),
      );
      // Reads inside the window are zero-effect and the window stayed open.
      expect(Accounts.requestRevision, revision);
      expect(port.release.isCompleted, false);
      expect(Accounts.installedAccounts(), isEmpty);
      // Success path: the same real restore must be observed directly so a
      // terminal error is never reported as success.
      port.release.complete();
      await restore;
    } finally {
      if (!port.release.isCompleted) {
        port.release.complete();
      }
      await restoreObserver;
    }
    // The busy state was terminally cleared by the completed restore.
    Accounts.captureLiveMemoryShadow().verifyCurrent();
  });

  test('a real pre-port public restore rejection fails promptly and leaves no restore window', () async {
    await _prepareEmptyTarget();
    AnonymousAccount().type.clear();
    final anonymous = AnonymousAccount();
    final port = _GatedRestorePort();
    final duplicate = _account(940040);
    final restore = Accounts.restoreEmptyCaptured(
      // Controlled invalid public fixture (the same public candidate twice):
      // the real API must reject before its write phase without any private
      // state mutation.
      accounts: [duplicate, duplicate],
      ownerOrdinals: [1, 2],
      anonymousJar: anonymous.cookieJar,
      anonymousPurposes: Set<AccountType>.of(anonymous.type),
      anonymousActivated: true,
      selections: [0, 1, 0, 0],
      persistencePort: port,
    );
    final restoreObserver = _observeTerminal(restore);
    try {
      // The old single await on port.started could never reach its finally
      // for this real pre-port rejection; phase-or-terminal observation must
      // fail promptly with the exact public error.
      await expectLater(
        _awaitStartedOrTerminal(started: port.started.future, terminal: restore),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'Captured restore requires fresh unique candidates',
          ),
        ),
      );
      expect(port.started.isCompleted, false);
      expect(port.release.isCompleted, false);
    } finally {
      if (!port.release.isCompleted) {
        port.release.complete();
      }
      await restoreObserver;
    }
    // No restore window may be left behind and the target stays usable.
    expect(port.release.isCompleted, true);
    expect(Accounts.installedAccounts(), isEmpty);
    Accounts.captureLiveMemoryShadow().verifyCurrent();
  });
}
