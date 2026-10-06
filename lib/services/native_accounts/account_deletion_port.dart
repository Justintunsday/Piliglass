import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:hive_ce/hive.dart';

/// Deletion forwarding only; revocation and exact stored-owner checks stay at
/// the caller. A revoked owner must still be able to delete its own credentials.
abstract interface class AccountDeletionPort {
  Future<void> deleteCookies(LoginAccount owner);

  Future<void> deleteLegacyAccount(Box<LoginAccount> box, String storageKey);
}

const AccountDeletionPort accountDeletionPort = DartAccountDeletionPort();

final class DartAccountDeletionPort implements AccountDeletionPort {
  const DartAccountDeletionPort();

  @override
  Future<void> deleteCookies(LoginAccount owner) => owner.cookieJar.deleteAll();

  @override
  Future<void> deleteLegacyAccount(Box<LoginAccount> box, String storageKey) =>
      box.delete(storageKey);
}
