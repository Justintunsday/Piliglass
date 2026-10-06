import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:hive_ce/hive.dart';

/// Persistence for pending installs; Accounts retains ownership and await gates.
/// A pending candidate is not yet an active credential owner.
abstract interface class AccountInstallPersistencePort {
  Future<void> writeLegacyInstall(
    Box<LoginAccount> box,
    String key,
    LoginAccount value,
  );

  Future<void> writeLegacyImport(
    Box<LoginAccount> box,
    Map<String, LoginAccount> values,
  );
}

/// Constant composition does not read the late Hive box during initialization.
const AccountInstallPersistencePort accountInstallPersistencePort =
    DartAccountInstallPersistencePort();

final class DartAccountInstallPersistencePort
    implements AccountInstallPersistencePort {
  const DartAccountInstallPersistencePort();

  @override
  Future<void> writeLegacyInstall(
    Box<LoginAccount> box,
    String key,
    LoginAccount value,
  ) => box.put(key, value);

  @override
  Future<void> writeLegacyImport(
    Box<LoginAccount> box,
    Map<String, LoginAccount> values,
  ) => box.putAll(values);
}
