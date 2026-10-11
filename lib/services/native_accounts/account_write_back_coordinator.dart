import 'dart:async';

/// One response write-back chain admitted by [AccountWriteBackCoordinator].
///
/// This is a lifecycle credential only: it never authorizes a write and never
/// replaces account owner/generation checks at the existing call sites. It must
/// be released exactly once, in a `finally`, after the chain's last real await.
final class AccountWriteBackOperation {
  AccountWriteBackOperation._(this._coordinator, this._token);

  final AccountWriteBackCoordinator _coordinator;
  final Object _token;
  bool _released = false;

  bool get isReleased => _released;

  /// Exactly-once effective release; repeated calls are no-ops so throw,
  /// cancel, finish, abandon and dispose paths cannot double-release.
  void release() {
    if (_released) return;
    _released = true;
    _coordinator._release(_token);
  }
}

/// Maintenance barrier token returned by [AccountWriteBackCoordinator.beginMaintenance].
///
/// While active, no new write chain can be admitted and the holder owns account
/// storage maintenance exclusively. Ending it either resumes admissions or
/// closes the coordinator permanently; it never clears an authority freeze.
final class AccountWriteBackMaintenance {
  AccountWriteBackMaintenance._(this._coordinator, this._token);

  final AccountWriteBackCoordinator _coordinator;
  final Object _token;
  bool _ended = false;

  bool get isEnded => _ended;

  void end({required bool permanent}) {
    if (_ended) return;
    _ended = true;
    _coordinator._endMaintenance(_token, permanent: permanent);
  }
}

/// Shared admission/drain gate for response write-back chains (Dio/AccountManager
/// response Cookie/redirect/Hive persistence and the Native HTTP lease finish).
///
/// Not an authority handoff, not a request permit and not an account identity:
/// owner/generation checks stay where they already are. Freezing rejects new
/// admissions and lets every admitted chain run to completion; drain completes
/// only when the last token is released. Clearing other tables (for example the
/// lease service's `dispose`) is never a token release.
final class AccountWriteBackCoordinator {
  AccountWriteBackCoordinator();

  bool _frozen = false;
  bool _maintenance = false;
  bool _closed = false;
  int _admitted = 0;
  final Map<Object, bool> _live = Map<Object, bool>.identity();
  final List<Completer<void>> _drainWaiters = <Completer<void>>[];
  final Map<Object, bool> _maintenanceTokens = Map<Object, bool>.identity();
  final List<Completer<void>> _maintenanceWaiters = <Completer<void>>[];

  bool get isFrozen => _frozen;
  bool get isMaintenanceActive => _maintenance;
  bool get isClosed => _closed;
  int get admittedCount => _admitted;
  int get liveOperationCount => _live.length;

  /// Returns a fresh operation, or null when frozen, under maintenance or
  /// permanently closed (the caller must perform zero writes and must not
  /// register an operation).
  AccountWriteBackOperation? tryAdmit() {
    if (_frozen || _maintenance || _closed) return null;
    final token = Object();
    _live[token] = true;
    _admitted++;
    return AccountWriteBackOperation._(this, token);
  }

  /// Freezes new admissions and completes after every admitted chain released.
  /// Repeated calls share the same drain condition; with no admitted chains the
  /// returned future is already complete.
  Future<void> freeze() {
    _frozen = true;
    if (_admitted == 0) return Future<void>.value();
    final waiter = Completer<void>();
    _drainWaiters.add(waiter);
    return waiter.future;
  }

  /// Waits for every currently admitted chain to release without blocking new
  /// admissions. Completes immediately when none are live; a chain admitted
  /// while waiting extends the wait because the count must reach zero first.
  /// This is not an exclusive maintenance barrier: use [beginMaintenance] when
  /// no new account write may start.
  Future<void> quiesce() {
    if (_admitted == 0) return Future<void>.value();
    final waiter = Completer<void>();
    _drainWaiters.add(waiter);
    return waiter.future;
  }

  /// Claims the exclusive maintenance barrier: rejects every later admission
  /// synchronously, waits for the currently admitted chains, and returns the
  /// token that must be ended exactly once. A closed coordinator returns null.
  /// Waiting behind an active maintenance is bounded by that holder's end.
  Future<AccountWriteBackMaintenance?> beginMaintenance() async {
    if (_closed) return null;
    while (_maintenance) {
      final waiter = Completer<void>();
      _maintenanceWaiters.add(waiter);
      await waiter.future;
      if (_closed) return null;
    }
    _maintenance = true;
    if (_admitted != 0) {
      final waiter = Completer<void>();
      _drainWaiters.add(waiter);
      await waiter.future;
    }
    final token = Object();
    _maintenanceTokens[token] = true;
    return AccountWriteBackMaintenance._(this, token);
  }

  void _endMaintenance(Object token, {required bool permanent}) {
    if (_maintenanceTokens.remove(token) == null) return;
    _maintenance = false;
    if (permanent) _closed = true;
    final waiters = List<Completer<void>>.of(_maintenanceWaiters);
    _maintenanceWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  void _release(Object token) {
    if (_live.remove(token) == null) return;
    _admitted--;
    assert(_admitted >= 0);
    if (_admitted != 0) return;
    final waiters = List<Completer<void>>.of(_drainWaiters);
    _drainWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }
}

/// Production composition shares one coordinator across every response
/// write-back chain. Tests inject their own instance.
final AccountWriteBackCoordinator accountWriteBackCoordinator =
    AccountWriteBackCoordinator();
