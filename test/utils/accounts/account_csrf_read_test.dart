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
}
