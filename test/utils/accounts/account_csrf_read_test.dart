import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_credential_reader_fixtures.dart';
import 'account_test_storage.dart';

LoginAccount _account(int mid) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'csrf-$mid',
    'SESSDATA': 'session-$mid',
  }),
  'access-$mid',
  'refresh-$mid',
)..activated = true;

void main() {
  late AccountTestStorage storage;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });
  setUp(() => storage.reset());
  tearDownAll(() => storage.close());

  test('csrfOf returns the real jar value for an installed owner', () async {
    final account = _account(950001);
    await Accounts.installCredentials(account);
    expect(Accounts.csrfOf(account), 'csrf-950001');
  });

  test('csrfOf routes the installed owner through the credential reader', () async {
    final account = _account(950002);
    await Accounts.installCredentials(account);
    final counter = CountingCredentialReader();
    expect(Accounts.csrfOf(account, reader: counter), 'csrf-950002');
    expect(counter.csrfReads, 1);
    expect(counter.captures, 0);
  });

  test('csrfOf falls back to the direct field for an uninstalled owner', () {
    final account = _account(950003);
    expect(Accounts.csrfOf(account), 'csrf-950003');
  });

  test('csrfOf falls back to the cached direct field after deletion', () async {
    final account = _account(950004);
    await Accounts.installCredentials(account);
    expect(Accounts.csrfOf(account), 'csrf-950004');
    await account.delete();
    expect(Accounts.csrfOf(account), 'csrf-950004');
  });

  test('boundCsrf is tagged: bound, not installed, and no-stamp legacy csrfOf', () async {
    final account = _account(950005);
    await Accounts.installCredentials(account);
    final counter = CountingCredentialReader();
    final bound = Accounts.boundCsrf(account, reader: counter);
    expect(bound.isBound, true);
    expect(bound.value, 'csrf-950005');
    expect(counter.boundCsrfReads, 1);
    expect(Accounts.boundCsrf(_account(950006)).isNotInstalled, true);
    await account.delete();
    // The revoked owner never reaches the reader: no stamp exists anymore, so
    // this is the explicit no-stamp legacy case, not a rejected binding.
    final afterDelete = Accounts.boundCsrf(account, reader: counter);
    expect(afterDelete.isNotInstalled, true);
    expect(counter.boundCsrfReads, 1);
    // The legacy wrapper keeps the historical value only for the no-stamp path.
    expect(Accounts.csrfOf(account), 'csrf-950005');
  });

  test('csrfOf fails closed when an existing stamp is rejected by the reader', () async {
    final account = _account(950007);
    await Accounts.installCredentials(account);
    const denied = DeniedCredentialReader();
    final bound = Accounts.boundCsrf(account, reader: denied);
    expect(bound.isRejected, true);
    expect(bound.value, isNull);
    expect(() => Accounts.csrfOf(account, reader: denied), throwsStateError);
    // The raw cached field exists but the wrapper must never return it here.
    expect(account.csrf, 'csrf-950007');
  });

  test('csrfOf fails closed when the stored owner object no longer matches', () async {
    final account = _account(950008);
    await Accounts.installCredentials(account);
    // A stored-object swap under the same key leaves the tracker stamp in place
    // while ownership verification fails: rejected, never a raw fallback.
    await Accounts.account.put('950008', _account(950008));
    final revision = Accounts.requestRevision;
    final bound = Accounts.boundCsrf(account);
    expect(bound.isRejected, true);
    expect(bound.value, isNull);
    expect(() => Accounts.csrfOf(account), throwsStateError);
    expect(Accounts.accessKeyOf(account), isNull);
    expect(Accounts.requestRevision, revision);
  });
}
