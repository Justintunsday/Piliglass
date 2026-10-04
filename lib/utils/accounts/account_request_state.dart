import 'dart:collection';

/// Tracks installed credential generations by account object identity.
///
/// [revision] invalidates snapshots that are being prepared. It is independent
/// of a request's credential generation: selection and ordinary Cookie changes
/// must not invalidate responses that still belong to an installed account.
final class AccountRequestState<T extends Object> {
  final HashMap<T, AccountRequestStamp<T>> _active =
      HashMap<T, AccountRequestStamp<T>>.identity();
  int _revision = 0;
  int _generation = 0;

  int get revision => _revision;

  /// Installs [account], or returns its existing stamp without changing state.
  ///
  /// An account that was revoked always receives a new generation, even when
  /// it is the same object (for example, a reset anonymous singleton).
  AccountRequestStamp<T> activate(T account) {
    final current = _active[account];
    if (current != null) return current;

    final stamp = AccountRequestStamp<T>._(account, ++_generation);
    _active[account] = stamp;
    changed();
    return stamp;
  }

  /// Revokes this identity and releases the registry's reference to it.
  void revoke(T account) {
    if (_active.remove(account) != null) changed();
  }

  /// Revokes every installed account, including accounts that are not selected.
  void revokeAll() {
    if (_active.isEmpty) return;
    _active.clear();
    changed();
  }

  /// Invalidates preparation snapshots without revoking credential generations.
  void changed() {
    _revision++;
  }

  /// Captures the installed generation without installing an unknown account.
  AccountRequestStamp<T>? capture(T account) => _active[account];

  /// Whether this exact stamp is still installed in this tracker.
  ///
  /// Stamp identity also rejects stamps created by another tracker, regardless
  /// of whether the account object and numeric generation happen to match.
  bool isCurrent(AccountRequestStamp<T> stamp) =>
      identical(_active[stamp.account], stamp);
}

/// An immutable reference to an account's installed credential generation.
///
/// A request can retain this stamp after revocation, but the tracker no longer
/// retains its account. Only [AccountRequestState.activate] can create stamps.
final class AccountRequestStamp<T extends Object> {
  const AccountRequestStamp._(this.account, this.generation);

  final T account;
  final int generation;
}
