import 'dart:collection';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/pages/mine/controller.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_request_state.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:hive_ce/hive.dart';

abstract final class Accounts {
  static late final Box<LoginAccount> account;
  static final List<Account> _accountMode = List.filled(
    AccountType.values.length,
    AnonymousAccount(),
  );
  static final List<Account> accountMode = UnmodifiableListView(_accountMode);
  static final _requestState = AccountRequestState<Account>();
  static final _owners = <String, LoginAccount>{};
  static final _pendingInstalls = <String, Object>{};
  // A failed Hive transaction may restore its previous in-memory object.
  // Restoring that object must not revive its revoked requests.
  static final _retired = Expando<bool>('retired account credentials');
  static Object? _anonymousReset;

  static int get requestRevision => _requestState.revision;
  static bool get mainEqVideo => main == video;
  static Account get main => _accountMode[AccountType.main.index];
  static Account get video => _accountMode[AccountType.video.index];
  static Account get heartbeat => _accountMode[AccountType.heartbeat.index];
  static Account get history {
    final heartbeat = Accounts.heartbeat;
    return heartbeat is AnonymousAccount ? main : heartbeat;
  }

  static AccountRequestStamp<Account>? captureRequest(Account value) {
    if (!ownsCredentials(value)) return null;
    return _requestState.capture(value);
  }

  static bool isCurrentRequest(AccountRequestStamp<Account> stamp) =>
      _requestState.isCurrent(stamp) && ownsCredentials(stamp.account);

  static bool ownsCredentials(Account value) {
    if (value is AnonymousAccount) {
      if (_anonymousReset != null) return false;
      _requestState.activate(value);
      return true;
    }
    return value is LoginAccount &&
        _retired[value] != true &&
        identical(_owners[value.storageKey], value) &&
        _requestState.capture(value) != null &&
        _ownsStoredObject(value);
  }

  static bool _ownsStoredObject(LoginAccount value) =>
      account.isOpen && identical(account.get(value.storageKey), value);

  static void notifyCookieMutation(Account value) {
    if (ownsCredentials(value)) _requestState.changed();
  }

  static void revokeCredentials(LoginAccount value) {
    _retired[value] = true;
    _requestState.revoke(value);
    if (identical(_owners[value.storageKey], value)) {
      _owners.remove(value.storageKey);
      _pendingInstalls.remove(value.storageKey);
    }
    _requestState.changed();
  }

  static Object beginAnonymousReset(AnonymousAccount value) {
    final reset = Object();
    _anonymousReset = reset;
    _requestState.revoke(value);
    _requestState.changed();
    return reset;
  }

  static bool isCurrentAnonymousReset(Object reset) =>
      identical(_anonymousReset, reset);

  static void completeAnonymousReset(
    AnonymousAccount value,
    Object reset,
  ) {
    if (!isCurrentAnonymousReset(reset)) return;
    _anonymousReset = null;
    _requestState.changed();
    _requestState.activate(value);
  }

  static Future<void> init() async {
    account = await Hive.openBox(
      'account',
      compactionStrategy: (int entries, int deletedEntries) {
        return deletedEntries > 2;
      },
    );
    _reconcileStoredOwners();
  }

  static void _reconcileStoredOwners() {
    final stored = <String, LoginAccount>{
      for (final entry in account.toMap().entries)
        if (entry.key == entry.value.storageKey)
          entry.value.storageKey: entry.value,
    };
    for (final entry in _owners.entries.toList()) {
      if (!identical(stored[entry.key], entry.value)) {
        revokeCredentials(entry.value);
      }
    }
    for (final entry in stored.entries) {
      final value = entry.value;
      if (_retired[value] == true) continue;
      _owners[entry.key] = value;
      if (!_pendingInstalls.containsKey(entry.key)) {
        _requestState.activate(value);
      }
    }
  }

  static Future<void> refresh() {
    _reconcileStoredOwners();
    _accountMode.fillRange(0, _accountMode.length, AnonymousAccount());
    for (final value in _owners.values) {
      for (final type in value.type) {
        _accountMode[type.index] = value;
      }
    }
    _requestState.changed();
    final selected = HashSet<Account>.identity()..addAll(_accountMode);
    return Future.wait(
      selected.where((value) => ownsCredentials(value) && !value.activated).map(
        Request.buvidActive,
      ),
    );
  }

  static ({LoginAccount value, Object operation}) _beginInstall(
    LoginAccount value, {
    required bool preserveTypes,
  }) {
    if (_retired[value] == true) {
      throw StateError('Cannot reinstall retired account credentials');
    }
    final key = value.storageKey;
    final previous = _owners[key] ?? account.get(key);
    if (preserveTypes && previous != null && !identical(previous, value)) {
      final previousTypes = Set<AccountType>.of(previous.type);
      value.type
        ..clear()
        ..addAll(previousTypes);
    }
    if (previous != null && !identical(previous, value)) {
      revokeCredentials(previous);
    }
    final operation = Object();
    _owners[key] = value;
    _pendingInstalls[key] = operation;
    for (int i = 0; i < _accountMode.length; i++) {
      final selected = _accountMode[i];
      if (selected is LoginAccount && selected.storageKey == key) {
        _accountMode[i] = value;
      }
    }
    _requestState.changed();
    return (value: value, operation: operation);
  }

  static void _completeInstall(
    ({LoginAccount value, Object operation}) installation,
  ) {
    final value = installation.value;
    final key = value.storageKey;
    if (!identical(_pendingInstalls[key], installation.operation) ||
        !identical(_owners[key], value) ||
        !_ownsStoredObject(value)) {
      throw StateError('Account credentials installation was superseded');
    }
    _pendingInstalls.remove(key);
    // Only the latest successful installation can start a new generation.
    _requestState.activate(value);
  }

  static void _failInstall(
    ({LoginAccount value, Object operation}) installation,
  ) {
    final value = installation.value;
    if (!identical(_pendingInstalls[value.storageKey], installation.operation)) {
      return;
    }
    revokeCredentials(value);
    for (int i = 0; i < _accountMode.length; i++) {
      if (identical(_accountMode[i], value)) {
        _accountMode[i] = AnonymousAccount();
      }
    }
  }

  static Future<void> installCredentials(
    LoginAccount value, {
    bool preserveTypes = true,
  }) async {
    if (ownsCredentials(value)) return;
    final installation = _beginInstall(value, preserveTypes: preserveTypes);
    try {
      await account.put(value.storageKey, value);
      _completeInstall(installation);
    } catch (_) {
      _failInstall(installation);
      rethrow;
    }
  }

  static Future<void> importCredentials(Map<Object?, LoginAccount> input) async {
    final values = <String, LoginAccount>{};
    for (final entry in input.entries) {
      final key = entry.value.storageKey;
      if (entry.key.toString() != key || values.containsKey(key)) {
        throw ArgumentError('Imported account key must match its unique MID');
      }
      if (_retired[entry.value] == true) {
        throw StateError('Cannot import retired account credentials');
      }
      values[key] = entry.value;
    }
    final installations = [
      for (final value in values.values)
        _beginInstall(value, preserveTypes: false),
    ];
    try {
      await account.putAll(values);
      for (final installation in installations) {
        _completeInstall(installation);
      }
    } catch (_) {
      for (final installation in installations) {
        _failInstall(installation);
      }
      rethrow;
    }
    await refresh();
  }

  static Future<void> clear() async {
    for (final value in _owners.values) {
      _retired[value] = true;
    }
    _owners.clear();
    _pendingInstalls.clear();
    _requestState.revokeAll();
    final anonymous = AnonymousAccount();
    _accountMode.fillRange(0, _accountMode.length, anonymous);
    _requestState.changed();
    final reset = anonymous.delete();
    await Future.wait([account.clear(), reset]);
    if (ownsCredentials(anonymous)) Request.buvidActive(anonymous);
  }

  static Future<void> deleteAll(Set<Account> accounts) async {
    final targets = HashSet<Account>.identity()
      ..addAll(
        accounts.where(
          (value) => value is LoginAccount
              ? _ownsStoredObject(value)
              : value is AnonymousAccount && ownsCredentials(value),
        ),
      );
    final isLoginMain = main.isLogin;
    for (final value in targets) {
      if (value is LoginAccount) revokeCredentials(value);
    }
    for (int i = 0; i < _accountMode.length; i++) {
      if (targets.contains(_accountMode[i])) {
        _accountMode[i] = AnonymousAccount();
      }
    }
    if (targets.isNotEmpty) _requestState.changed();
    await Future.wait([
      for (final value in targets.whereType<AnonymousAccount>()) value.delete(),
      for (final value in targets.whereType<LoginAccount>()) value.delete(),
    ]);
    if (isLoginMain && !main.isLogin) {
      await LoginUtils.onLogoutMain();
    }
  }

  static Account _resolveSelection(Account value) {
    if (value is LoginAccount && !ownsCredentials(value)) {
      final current = _owners[value.storageKey];
      if (current != null && ownsCredentials(current)) return current;
    }
    if (!ownsCredentials(value)) {
      throw StateError('Cannot select unavailable account credentials');
    }
    return value;
  }

  static void selectTemporarily(AccountType key, Account value) {
    _accountMode[key.index] = _resolveSelection(value);
    _requestState.changed();
  }

  static Future<void> set(AccountType key, Account value) async {
    final selected = _resolveSelection(value);
    final stamp = captureRequest(selected)!;
    final oldAccount = _accountMode[key.index]..type.remove(key);
    _accountMode[key.index] = selected..type.add(key);
    _requestState.changed();
    await Future.wait([
      ?selected.onChange(),
      if (!identical(oldAccount, selected)) ?oldAccount.onChange(),
    ]);
    if (!identical(_accountMode[key.index], selected) ||
        !isCurrentRequest(stamp)) {
      return;
    }
    if (!selected.activated) await Request.buvidActive(selected);
    if (!identical(_accountMode[key.index], selected) ||
        !isCurrentRequest(stamp)) {
      return;
    }
    switch (key) {
      case AccountType.main:
        await (selected.isLogin
            ? LoginUtils.onLoginMain()
            : LoginUtils.onLogoutMain());
        break;
      case AccountType.heartbeat:
        MineController.anonymity.value = !selected.isLogin;
        break;
      default:
        break;
    }
  }

  @pragma('vm:prefer-inline')
  static Account get(AccountType key) => _accountMode[key.index];
}
