import 'dart:async';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/account_install_persistence_port.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'account_test_storage.dart';
import 'native_account_envelope_fixtures.dart';

/// Real Hive writes behind a controllable seam: the captured-restore window
/// stays open while stamped reader reads are performed against it.
final class _GatedInstallPort implements AccountInstallPersistencePort {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> writeLegacyInstall(
    Box<LoginAccount> box,
    String key,
    LoginAccount value,
  ) => accountInstallPersistencePort.writeLegacyInstall(box, key, value);

  @override
  Future<void> writeLegacyImport(
    Box<LoginAccount> box,
    Map<String, LoginAccount> values,
  ) async {
    started.complete();
    await release.future;
    await accountInstallPersistencePort.writeLegacyImport(box, values);
  }
}

LoginAccount _account(int mid) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'csrf-$mid',
    'SESSDATA': 'session-$mid',
  }),
  'access-$mid',
  'refresh-$mid',
)..activated = true;

/// Deterministic empty-target fixture: delete/reset only, with no clear()'s
/// fire-and-forget buvid activation. All actual Hive/jar deletes are awaited.
Future<void> _prepareEmptyTarget() async {
  final anonymous = AnonymousAccount();
  for (final purpose in AccountType.values) {
    Accounts.selectTemporarily(purpose, anonymous);
  }
  for (final account in Accounts.account.values.toList()) {
    await account.delete();
  }
  await anonymous.delete();
  AnonymousAccount().activated = true;
}

void main() {
  late AccountTestStorage storage;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });
  setUp(() async {
    await _prepareEmptyTarget();
    AnonymousAccount().type.clear();
  });
  tearDownAll(() => storage.close());

  test('the anonymous captured-restore window rejects stamped reads without raw fallback', () async {
    final anonymous = AnonymousAccount();
    final candidate = envelopeFixtureAccount('2', purposes: {AccountType.main});
    final port = _GatedInstallPort();
    final revision = Accounts.requestRevision;
    final restore = Accounts.restoreEmptyCaptured(
      accounts: [candidate],
      ownerOrdinals: [1],
      anonymousJar: anonymous.cookieJar,
      anonymousPurposes: Set<AccountType>.of(anonymous.type),
      anonymousActivated: true,
      selections: [0, 1, 0, 0],
      persistencePort: port,
    );
    await port.started.future;

    // The captured-restore window is open: the anonymous stamp still exists
    // but ownership is suspended, so every stamped read must fail closed.
    expect(Accounts.boundCsrf(anonymous).isRejected, true);
    expect(Accounts.boundAccessKey(anonymous).isRejected, true);
    expect(Accounts.boundCsrf(anonymous).value, isNull);
    expect(Accounts.boundAccessKey(anonymous).value, isNull);
    expect(() => Accounts.csrfOf(anonymous), throwsStateError);
    expect(Accounts.accessKeyOf(anonymous), isNull);
    // Reads inside the window are zero-effect.
    expect(Accounts.requestRevision, revision);

    port.release.complete();
    await restore;

    // After the restore the freshly installed anonymous context is bound again.
    expect(Accounts.boundCsrf(anonymous).isBound, true);
    expect(Accounts.boundAccessKey(anonymous).isBound, true);
    expect(Accounts.requestRevision, greaterThan(revision));

    // Explicit no-stamp legacy compatibility stays separate from the rejected
    // stamped context: an uninstalled owner keeps the historical direct read.
    expect(Accounts.csrfOf(_account(970001)), 'csrf-970001');
    expect(Accounts.accessKeyOf(_account(970001)), 'access-970001');
  });
}
