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

  test('accessKeyOf returns the real value for an installed owner', () async {
    final account = _account(960001);
    await Accounts.installCredentials(account);
    expect(Accounts.accessKeyOf(account), 'access-960001');
  });

  test('accessKeyOf routes the installed owner through the credential reader', () async {
    final account = _account(960002);
    await Accounts.installCredentials(account);
    final counter = CountingCredentialReader();
    expect(Accounts.accessKeyOf(account, reader: counter), 'access-960002');
    expect(counter.accessKeyReads, 1);
    expect(counter.captures, 0);
    expect(counter.csrfReads, 0);
  });

  test('accessKeyOf falls back to the direct field for an uninstalled owner', () {
    final account = _account(960003);
    expect(Accounts.accessKeyOf(account), 'access-960003');
  });
}
