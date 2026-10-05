import 'dart:io';

import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';

/// A narrow Dart writer boundary, not an authority handoff or request permit.
/// Callers retain their original generation checks, parsing and await gates.
abstract interface class AccountCookieMutationPort {
  Future<void> saveResponseCookies(Account owner, Uri uri, List<Cookie> cookies);

  Future<void>? persistLegacyAccount(LoginAccount owner);
}

/// Constant composition avoids reading the late Hive box during initialization.
const AccountCookieMutationPort accountCookieMutationPort =
    DartAccountCookieMutationPort();

final class DartAccountCookieMutationPort implements AccountCookieMutationPort {
  const DartAccountCookieMutationPort();

  @override
  Future<void> saveResponseCookies(Account owner, Uri uri, List<Cookie> cookies) {
    if (!Accounts.ownsCredentials(owner)) {
      throw StateError('Cannot mutate unavailable account credentials');
    }
    // The real jar mutates before returning its Future. Do not defer this call.
    // Revision notification remains at the existing caller's mutation boundary.
    return owner.cookieJar.saveFromResponse(uri, cookies);
  }

  @override
  Future<void>? persistLegacyAccount(LoginAccount owner) {
    if (!Accounts.ownsCredentials(owner)) return null;
    final box = Accounts.account;
    if (!box.isOpen || !identical(box.get(owner.storageKey), owner)) return null;
    // Forward the actual completion/error. It does not prove full-attrs durability.
    return box.put(owner.storageKey, owner);
  }
}
