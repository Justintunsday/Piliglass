import 'dart:collection';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_request_state.dart';
import 'package:uuid/uuid.dart';

final class NativeAccountSnapshotException implements Exception {
  const NativeAccountSnapshotException(this.code);
  final String code;
}

/// Read-only capture of the real Hive owners. This service never installs credentials.
final class NativeAccountSnapshotService {
  NativeAccountSnapshotService({Future<void> Function()? checkpoint})
    : _checkpoint = checkpoint ?? _yield;

  final String authorityEpoch = const Uuid().v4();
  final Future<void> Function() _checkpoint;
  final Expando<String> _tokens = Expando('native account owner tokens');

  static Future<void> _yield() => Future<void>.value();

  Map<String, Object?>? currentOwnerWire(Account account) {
    final stamp = Accounts.captureRequest(account);
    if (stamp == null) return null;
    return {'authorityEpoch': authorityEpoch, ..._identity(stamp)};
  }

  Account? resolveOwner({required String authorityEpoch, required String ownerToken, required int generation}) {
    if (authorityEpoch != this.authorityEpoch || !Accounts.account.isOpen) return null;
    for (final account in <Account>[AnonymousAccount(), ...Accounts.account.values]) {
      final stamp = Accounts.captureRequest(account);
      if (stamp != null && stamp.generation == generation && _tokens[stamp] == ownerToken &&
          Accounts.isCurrentRequest(stamp)) return account;
    }
    return null;
  }

  Future<Map<String, Object?>> selectionSnapshot() async {
    final capture = _capture();
    await _checkpoint();
    _verify(capture);
    return capture.value;
  }

  /// Contains secrets. Only an explicit staging import may consume this value;
  /// it must never be logged or placed in an ordinary settings export.
  Future<Map<String, Object?>> stagingExport() async {
    final capture = _capture();
    final entries = [
      for (final account in capture.accounts)
        {
          'identity': _identity(capture.stamps[account]!),
          'accessKey': account.accessKey,
          'refreshToken': account.refresh,
          'ignoreExpires': account.cookieJar.ignoreExpires,
          // The Hive adapter already discarded non-root attributes on reopen.
          // Remaining in-memory attributes below are retained, never reconstructed.
          'legacyHiveAttributesIncomplete': true,
          'cookies': _cookies(account),
        },
    ];
    await _checkpoint();
    _verify(capture);
    return {
      'schemaVersion': 1,
      'authority': 'dartHive',
      'nativeWritesAllowed': false,
      'snapshot': capture.value,
      'entries': entries,
    };
  }

  _Capture _capture() {
    if (!Accounts.account.isOpen) {
      throw const NativeAccountSnapshotException('unavailable');
    }
    final anonymous = AnonymousAccount();
    final accounts = HashSet<Account>.identity()
      ..add(anonymous)
      ..addAll(Accounts.account.values.where(Accounts.ownsCredentials))
      ..addAll(Accounts.accountMode);
    if (accounts.length > 256) {
      throw const NativeAccountSnapshotException('capacityExceeded');
    }
    final stamps = HashMap<Account, AccountRequestStamp<Account>>.identity();
    for (final account in accounts) {
      final stamp = Accounts.captureRequest(account);
      if (stamp == null) {
        throw const NativeAccountSnapshotException('snapshotChanged');
      }
      stamps[account] = stamp;
    }
    final revision = Accounts.requestRevision;
    final descriptors = [for (final account in accounts) _descriptor(account, stamps[account]!)];
    descriptors.sort((a, b) => (a['mid']! as int).compareTo(b['mid']! as int));
    final selected = List<Account>.of(Accounts.accountMode);
    final selections = [
      for (final purpose in AccountType.values)
        {
          'purpose': purpose.name,
          'identity': _identity(stamps[selected[purpose.index]]!),
          'temporary': _temporary(purpose, selected[purpose.index]),
        },
    ];
    final history = Accounts.history;
    final value = <String, Object?>{
      'schemaVersion': 1,
      'authority': 'dartHive',
      'authorityEpoch': authorityEpoch,
      'revision': revision,
      'nativeWritesAllowed': false,
      'accounts': descriptors,
      'selections': selections,
      'history': _identity(stamps[history]!),
    };
    return _Capture(List.of(accounts), stamps, selected, revision, value);
  }

  void _verify(_Capture capture) {
    if (!Accounts.account.isOpen || capture.revision != Accounts.requestRevision ||
        capture.stamps.values.any((stamp) => !Accounts.isCurrentRequest(stamp))) {
      throw const NativeAccountSnapshotException('snapshotChanged');
    }
    for (final purpose in AccountType.values) {
      if (!identical(capture.selected[purpose.index], Accounts.get(purpose))) {
        throw const NativeAccountSnapshotException('snapshotChanged');
      }
    }
    final current = _capture().value;
    // Compare copied public values as well: mutable activated/type fields can
    // change independently of a credentials generation.
    if (!_equal(capture.value, current)) {
      throw const NativeAccountSnapshotException('snapshotChanged');
    }
  }

  bool _temporary(AccountType purpose, Account selected) {
    Account persisted = AnonymousAccount();
    for (final account in Accounts.account.values) {
      if (Accounts.ownsCredentials(account) && account.type.contains(purpose)) {
        persisted = account;
      }
    }
    return !identical(selected, persisted);
  }

  Map<String, Object?> _identity(AccountRequestStamp<Account> stamp) => {
    'ownerToken': _tokens[stamp] ??= const Uuid().v4(),
    'generation': stamp.generation,
  };

  Map<String, Object?> _descriptor(Account account, AccountRequestStamp<Account> stamp) => {
    'identity': _identity(stamp),
    'mid': account.mid,
    'isLogin': account.isLogin,
    'activated': account.activated,
    'hasAccessKey': account.accessKey?.isNotEmpty ?? false,
    'hasRefreshToken': account.refresh?.isNotEmpty ?? false,
    'persistedPurposes': [for (final purpose in AccountType.values) if (account is LoginAccount && account.type.contains(purpose)) purpose.name],
  };

  static List<Map<String, Object?>> _cookies(Account account) {
    final result = <Map<String, Object?>>[];
    final jar = account.cookieJar;
    for (final bucket in [(hostOnly: false, values: jar.domainCookies), (hostOnly: true, values: jar.hostCookies)]) {
      for (final domain in bucket.values.entries) {
        for (final path in domain.value.entries) {
          for (final stored in path.value.values) {
            final cookie = stored.cookie;
            result.add({
              'name': cookie.name, 'value': cookie.value,
              'domain': domain.key, 'path': path.key, 'hostOnly': bucket.hostOnly,
              'cookieDomain': cookie.domain, 'cookiePath': cookie.path,
              'secure': cookie.secure, 'httpOnly': cookie.httpOnly,
              'sameSite': cookie.sameSite?.name,
              'expiresMicroseconds': cookie.expires?.microsecondsSinceEpoch,
              'maxAgeSeconds': cookie.maxAge,
              'createdSeconds': stored.createTimeStamp,
              'sequence': result.length,
            });
          }
        }
      }
    }
    return result;
  }

  static bool _equal(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length && a.keys.every((key) => b.containsKey(key) && _equal(a[key], b[key]));
    }
    if (a is List && b is List) {
      return a.length == b.length && Iterable<int>.generate(a.length).every((i) => _equal(a[i], b[i]));
    }
    return a == b;
  }
}

final class _Capture {
  _Capture(this.accounts, this.stamps, this.selected, this.revision, this.value);
  final List<Account> accounts;
  final Map<Account, AccountRequestStamp<Account>> stamps;
  final List<Account> selected;
  final int revision;
  final Map<String, Object?> value;
}
