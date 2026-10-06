part of '../accounts.dart';

/// Contains secrets. Owned read-only candidate, never a request permission.
final class AccountLiveMemoryShadowCapture {
  AccountLiveMemoryShadowCapture._(
    this.value,
    this._box,
    this._revision,
    this._records,
    this._stamps,
    this._selected,
    this._history,
  );

  final Map<String, Object?> value;
  final Box<LoginAccount> _box;
  final int _revision;
  final List<Account> _records;
  final List<AccountRequestStamp<Account>> _stamps;
  final List<Account> _selected;
  final Account _history;

  /// Full recapture detects raw jar/type/activated changes without notification.
  /// Equal endpoints do not prove writers were frozen during an await.
  void verifyCurrent() {
    final current = _captureAccountLiveMemoryShadow();
    if (!identical(_box, current._box) ||
        _revision != current._revision ||
        !_sameReferences(_records, current._records) ||
        !_sameReferences(_stamps, current._stamps) ||
        !_sameReferences(_selected, current._selected) ||
        !identical(_history, current._history) ||
        !_sameOwned(value, current.value)) {
      throw const AccountLiveMemoryShadowException('snapshotChanged');
    }
  }
}

final class AccountLiveMemoryShadowException implements Exception {
  const AccountLiveMemoryShadowException(this.code);
  final String code;
}

AccountLiveMemoryShadowCapture _captureAccountLiveMemoryShadow() {
  final Box<LoginAccount> box;
  try {
    box = Accounts.account;
  } on Error {
    throw const AccountLiveMemoryShadowException('unavailable');
  }
  if (!box.isOpen) {
    throw const AccountLiveMemoryShadowException('unavailable');
  }
  if (Accounts._pendingInstalls.isNotEmpty || Accounts._anonymousReset != null) {
    throw const AccountLiveMemoryShadowException('busy');
  }
  if (box.length + 1 > 256 || Accounts._owners.length + 1 > 256) {
    throw const AccountLiveMemoryShadowException('capacityExceeded');
  }
  // Never call the anonymous factory here: a dormant singleton would create
  // its jar, buvid and protocol headers before capture could reject it.
  final anonymousStamp = Accounts._requestState
      .captureSingleOfType<AnonymousAccount>();
  if (anonymousStamp == null ||
      !Accounts._requestState.isCurrent(anonymousStamp)) {
    throw const AccountLiveMemoryShadowException('unavailable');
  }
  final revision = Accounts._requestState.revision;
  final stored = box.toMap();
  final owners = List<MapEntry<String, LoginAccount>>.of(Accounts._owners.entries);
  final records = <Account>[anonymousStamp.account];
  final ids = HashMap<Account, int>.identity()..[records.first] = 0;
  final storedOrder = <Map<String, Object?>>[];
  // Conservative reservation before allocating envelope metadata/ID arrays.
  final budget = NativeOrderedCookieExportBudget()
    ..reserveNodes(64 + 40 * (stored.length + 1))
    ..reserveUnits(2048 + 512 * (stored.length + 1));
  for (final entry in stored.entries) {
    final account = entry.value;
    final key = entry.key;
    if (key is! String ||
        key != account.storageKey ||
        !identical(Accounts._owners[key], account) ||
        Accounts._retired[account] == true ||
        ids.containsKey(account)) {
      throw const AccountLiveMemoryShadowException('invalidStoredOwner');
    }
    ids[account] = records.length;
    records.add(account);
    storedOrder.add({
      'keyUnits': budget.units(key, 4096),
      'record': ids[account],
    });
  }
  if (owners.length != stored.length) {
    throw const AccountLiveMemoryShadowException('invalidStoredOwner');
  }
  final ownerOrder = <Map<String, Object?>>[];
  for (final entry in owners) {
    if (!identical(stored[entry.key], entry.value) ||
        !ids.containsKey(entry.value)) {
      throw const AccountLiveMemoryShadowException('invalidStoredOwner');
    }
    ownerOrder.add({
      'keyUnits': budget.units(entry.key, 4096),
      'record': ids[entry.value],
    });
  }
  final stamps = <AccountRequestStamp<Account>>[];
  for (final account in records) {
    final stamp = Accounts._requestState.capture(account);
    if (stamp == null || !Accounts._requestState.isCurrent(stamp)) {
      throw const AccountLiveMemoryShadowException('unavailable');
    }
    stamps.add(stamp);
  }
  final selected = List<Account>.of(Accounts._accountMode);
  final history = Accounts.history;
  if (selected.any((account) => !ids.containsKey(account)) ||
      !ids.containsKey(history)) {
    throw const AccountLiveMemoryShadowException('unavailable');
  }
  final entries = <Map<String, Object?>>[];
  for (var i = 0; i < records.length; i++) {
    final account = records[i];
    entries.add({
      'record': i,
      'generation': stamps[i].generation,
      'storageKeyUnits': account is LoginAccount
          ? budget.units(account.storageKey, 4096)
          : null,
      'mid': account.mid,
      'isLogin': account.isLogin,
      'accessKeyUnits': budget.optionalUnits(account.accessKey, 65536),
      'refreshTokenUnits': budget.optionalUnits(account.refresh, 65536),
      'persistedPurposes': [for (final purpose in account.type) purpose.name],
      'activated': account.activated,
      'jar': NativeOrderedCookieJarExporter.export(
        account.cookieJar,
        cumulativeBudget: budget,
      ),
    });
  }
  final value = <String, Object?>{
    'schemaVersion': 2,
    'scope': 'coherentLiveMemoryShadow',
    'identityScope': 'captureLocal',
    'revision': revision,
    'durableIdentityConfigured': false,
    'durabilityVerified': false,
    'authoritySwitchAllowed': false,
    'nativeWritesAllowed': false,
    'records': entries,
    'storedOrder': storedOrder,
    'ownerOrder': ownerOrder,
    'selectionPurposes': [for (final purpose in AccountType.values) purpose.name],
    'selections': [for (final account in selected) ids[account]],
    'history': ids[history],
  };
  NativeOrderedCookieJarExporter.verifyWireCapacity(value);
  if (!box.isOpen ||
      revision != Accounts._requestState.revision ||
      Accounts._pendingInstalls.isNotEmpty ||
      Accounts._anonymousReset != null ||
      stamps.any((stamp) => !Accounts._requestState.isCurrent(stamp)) ||
      box.length != stored.length ||
      Accounts._owners.length != owners.length ||
      !_sameOwnerEntries(stored.entries, box.toMap().entries) ||
      !_sameOwnerEntries(owners, Accounts._owners.entries) ||
      !_sameReferences(selected, Accounts._accountMode) ||
      !identical(history, Accounts.history)) {
    throw const AccountLiveMemoryShadowException('snapshotChanged');
  }
  return AccountLiveMemoryShadowCapture._(
    _freezeShadow(value) as Map<String, Object?>,
    box,
    revision,
    List.unmodifiable(records),
    List.unmodifiable(stamps),
    List.unmodifiable(selected),
    history,
  );
}

bool _sameOwnerEntries(
  Iterable<MapEntry<dynamic, LoginAccount>> left,
  Iterable<MapEntry<dynamic, LoginAccount>> right,
) {
  final a = left.iterator;
  final b = right.iterator;
  while (a.moveNext()) {
    if (!b.moveNext() ||
        a.current.key != b.current.key ||
        !identical(a.current.value, b.current.value)) {
      return false;
    }
  }
  return !b.moveNext();
}

bool _sameReferences(List<Object> left, List<Object> right) =>
    left.length == right.length &&
    Iterable<int>.generate(left.length).every((i) => identical(left[i], right[i]));

bool _sameOwned(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) => right.containsKey(key) && _sameOwned(left[key], right[key]),
        );
  }
  if (left is List && right is List) {
    return left.length == right.length &&
        Iterable<int>.generate(
          left.length,
        ).every((i) => _sameOwned(left[i], right[i]));
  }
  return left == right;
}

Object? _freezeShadow(Object? value) {
  if (value is Map<String, Object?>) {
    return Map<String, Object?>.unmodifiable(
      value.map((key, child) => MapEntry(key, _freezeShadow(child))),
    );
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freezeShadow));
  return value;
}
