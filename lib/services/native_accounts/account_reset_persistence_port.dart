import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:hive_ce/hive.dart';

/// Reset persistence forwarding only. Revocation, session fields, reseeding and
/// reset completion remain at the caller; a resetting owner is already revoked.
abstract interface class AccountResetPersistencePort {
  Future<void> clearAnonymousCookies(AnonymousAccount owner);

  Future<int> clearLegacyAccounts(Box<LoginAccount> box);
}

const AccountResetPersistencePort accountResetPersistencePort =
    DartAccountResetPersistencePort();

final class DartAccountResetPersistencePort
    implements AccountResetPersistencePort {
  const DartAccountResetPersistencePort();

  @override
  Future<void> clearAnonymousCookies(AnonymousAccount owner) =>
      owner.cookieJar.deleteAll();

  @override
  Future<int> clearLegacyAccounts(Box<LoginAccount> box) => box.clear();
}
