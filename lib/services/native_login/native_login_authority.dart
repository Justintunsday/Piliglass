import 'dart:async';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/native_account_snapshot_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_request_state.dart';

final class NativeLoginAuthorityException implements Exception {
  const NativeLoginAuthorityException(this.code);
  final String code;
}

/// The only writer is still Accounts/Hive. Native transport and Keychain remain
/// disabled; this adapter is not permission to run an unverified native login.
final class NativeLoginAuthority {
  NativeLoginAuthority(this.accounts, {FutureOr<void> Function()? onChanged})
    : _onChanged = onChanged;

  final NativeAccountSnapshotService accounts;
  final FutureOr<void> Function()? _onChanged;
  final Set<String> _operations = {};

  Future<Map<String, Object?>> handle(String method, Object? arguments) async {
    try {
      final values = _map(arguments);
      final operationID = _string(values['operationID']);
      if (operationID.isEmpty || operationID.length > 128 || _operations.contains(operationID)) {
        throw const NativeLoginAuthorityException('operationAlreadyConsumed');
      }
      // Bound the registry without allowing a completed write to be replayed:
      // composition replaces this service (and its epoch) when the cap is hit.
      if (_operations.length >= 4096) {
        throw const NativeLoginAuthorityException('authorityCapacityReached');
      }
      _operations.add(operationID);
      switch (method) {
        case 'installNativeLoginCredentials':
          _keys(values, {'operationID', 'credentials', 'method', 'purposes'});
          return await _install(values);
        case 'deleteNativeLoginAccounts':
          _keys(values, {'operationID', 'owners'});
          return await _delete(values);
        default:
          throw const NativeLoginAuthorityException('unsupportedCommand');
      }
    } on NativeLoginAuthorityException catch (error) {
      return {'state': 'error', 'code': error.code, 'nativeAuthorityEnabled': false};
    } catch (_) {
      // No exception description: it may contain a Cookie or access token.
      return {'state': 'error', 'code': 'authorityWriteFailed', 'nativeAuthorityEnabled': false};
    }
  }

  Future<Map<String, Object?>> _install(Map<String, Object?> values) async {
    final method = _string(values['method']);
    if (!{'qr', 'password', 'sms', 'cookie'}.contains(method)) {
      throw const NativeLoginAuthorityException('invalidArguments');
    }
    final credentials = _map(values['credentials']);
    _keys(credentials, {'mid', 'accessToken', 'refreshToken', 'cookies'});
    final mid = credentials['mid'];
    if (mid is! int || mid <= 0) throw const NativeLoginAuthorityException('invalidCredentials');
    final access = _nullableString(credentials['accessToken']);
    final refresh = _nullableString(credentials['refreshToken']);
    if (method != 'cookie' && (access == null || access.isEmpty || refresh == null)) {
      throw const NativeLoginAuthorityException('invalidCredentials');
    }
    final entries = credentials['cookies'];
    if (entries is! List || entries.isEmpty || entries.length > 128) {
      throw const NativeLoginAuthorityException('invalidCredentials');
    }
    final cookies = <String, String>{};
    for (final entry in entries) {
      final cookie = _map(entry);
      _keys(cookie, {'name', 'value', 'domain', 'path', 'expiresEpochSeconds', 'secure', 'httpOnly'});
      final name = _string(cookie['name']), value = _string(cookie['value']);
      // Hive's actual CookieJar adapter cannot persist these attributes yet.
      // Fail explicitly rather than silently reporting a durable full import.
      if (!{'bilibili.com', '.bilibili.com'}.contains(cookie['domain']) || cookie['path'] != '/' ||
          cookie['expiresEpochSeconds'] != null || cookie['secure'] != false || cookie['httpOnly'] != false) {
        throw const NativeLoginAuthorityException('cookieAttributesNotPersistable');
      }
      if (name.isEmpty || RegExp(r'[\r\n;=\s]').hasMatch(name) || RegExp(r'[\r\n]').hasMatch(value) ||
          cookies.containsKey(name)) throw const NativeLoginAuthorityException('invalidCredentials');
      cookies[name] = value;
    }
    if (cookies['DedeUserID'] != mid.toString() || cookies['bili_jct']?.isNotEmpty != true ||
        cookies['SESSDATA']?.isNotEmpty != true) throw const NativeLoginAuthorityException('invalidCredentials');
    final rawPurposes = values['purposes'];
    final Set<AccountType>? purposes;
    if (rawPurposes == null) {
      purposes = null;
    } else if (rawPurposes is List && rawPurposes.every((value) => value is String)) {
      purposes = {};
      for (final value in rawPurposes) {
        final found = AccountType.values.where((purpose) => purpose.name == value).firstOrNull;
        if (found == null || !purposes.add(found)) throw const NativeLoginAuthorityException('invalidArguments');
      }
    } else { throw const NativeLoginAuthorityException('invalidArguments'); }
    final account = LoginAccount(BiliCookieJar.fromJson(cookies), access, refresh);
    await Accounts.installCredentials(account);
    final stamp = Accounts.captureRequest(account);
    final owner = accounts.currentOwnerWire(account);
    if (stamp == null || owner == null) {
      throw const NativeLoginAuthorityException('credentialsSuperseded');
    }
    _verifyInstallation(account, stamp, owner);
    if (purposes != null) {
      for (final purpose in purposes) {
        // Accounts.set can resolve an obsolete object to a newer same-MID
        // owner. Do not carry this login's remaining selections onto that owner.
        _verifyInstallation(account, stamp, owner);
        await Accounts.set(purpose, account);
        _verifyInstallation(account, stamp, owner);
      }
    }
    // Existing app login resets anonymous credentials; Cookie login does not.
    _verifyInstallation(account, stamp, owner);
    if (method != 'cookie') {
      await AnonymousAccount().delete();
      _verifyInstallation(account, stamp, owner);
    }
    await _onChanged?.call();
    // Refresh can await network/storage work. Its completion is not proof that
    // this original owner is still installed; never acknowledge its successor.
    _verifyInstallation(account, stamp, owner);
    return {'state': 'installed', 'owner': owner, 'needsPurposeSelection': !Accounts.main.isLogin,
            'nativeAuthorityEnabled': false};
  }

  void _verifyInstallation(LoginAccount account, AccountRequestStamp<Account> stamp,
      Map<String, Object?> originalOwner) {
    final currentOwner = accounts.currentOwnerWire(account);
    if (!identical(stamp.account, account) || !Accounts.ownsCredentials(account) ||
        !Accounts.isCurrentRequest(stamp) || currentOwner == null ||
        currentOwner['authorityEpoch'] != originalOwner['authorityEpoch'] ||
        currentOwner['ownerToken'] != originalOwner['ownerToken'] ||
        currentOwner['generation'] != originalOwner['generation']) {
      // Partial selection changes already belong to Accounts. Rolling them
      // back here could revoke or overwrite a newer credentials installation.
      throw const NativeLoginAuthorityException('credentialsSuperseded');
    }
  }

  Future<Map<String, Object?>> _delete(Map<String, Object?> values) async {
    final owners = values['owners'];
    if (owners is! List || owners.length > 256) throw const NativeLoginAuthorityException('invalidArguments');
    final targets = <Account>{};
    for (final value in owners) {
      final owner = _map(value);
      _keys(owner, {'authorityEpoch', 'ownerToken', 'generation'});
      final generation = owner['generation'];
      if (generation is! int || generation <= 0) throw const NativeLoginAuthorityException('invalidArguments');
      final target = accounts.resolveOwner(authorityEpoch: _string(owner['authorityEpoch']),
          ownerToken: _string(owner['ownerToken']), generation: generation);
      if (target is! LoginAccount || !targets.add(target)) {
        throw const NativeLoginAuthorityException('staleOwner');
      }
    }
    // resolveOwner and deleteAll have no intervening await: a same-MID replace
    // cannot be accidentally deleted by an old remote logout result.
    await Accounts.deleteAll(targets);
    await _onChanged?.call();
    return {'state': 'deleted', 'count': targets.length, 'nativeAuthorityEnabled': false};
  }

  static Map<String, Object?> _map(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const NativeLoginAuthorityException('invalidArguments');
    }
    return {for (final entry in value.entries) entry.key as String: entry.value};
  }
  static String _string(Object? value) {
    if (value is! String) throw const NativeLoginAuthorityException('invalidArguments');
    return value;
  }
  static String? _nullableString(Object? value) => value == null ? null : _string(value);
  static void _keys(Map<String, Object?> value, Set<String> keys) {
    if (value.length != keys.length || !keys.every(value.containsKey)) {
      throw const NativeLoginAuthorityException('invalidArguments');
    }
  }
}
