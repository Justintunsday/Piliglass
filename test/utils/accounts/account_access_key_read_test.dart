import 'package:PiliPlus/services/native_accounts/account_credential_reader.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_credential_reader_fixtures.dart';
import 'account_test_storage.dart';

LoginAccount _account(int mid, {bool withAccessKey = true}) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'csrf-$mid',
    'SESSDATA': 'session-$mid',
  }),
  withAccessKey ? 'access-$mid' : null,
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

  test('boundAccessKey is tagged: bound, not installed, and legacy accessKeyOf rules', () async {
    final account = _account(960004);
    await Accounts.installCredentials(account);
    final counter = CountingCredentialReader();
    final bound = Accounts.boundAccessKey(account, reader: counter);
    expect(bound.isBound, true);
    expect(bound.value, 'access-960004');
    expect(counter.boundAccessKeyReads, 1);
    expect(Accounts.boundAccessKey(_account(960005)).isNotInstalled, true);
    await account.delete();
    expect(Accounts.boundAccessKey(account).isNotInstalled, true);
    expect(counter.boundAccessKeyReads, 1);
    // A retired owner must not fall back to its stale direct field.
    expect(Accounts.accessKeyOf(account), isNull);
    // Uninstalled owners keep the legacy compatibility read.
    expect(Accounts.accessKeyOf(_account(960006)), 'access-960006');
  });

  test('a bound nullable access key is data, not a rejection', () async {
    final account = _account(960007, withAccessKey: false);
    await Accounts.installCredentials(account);
    final bound = Accounts.boundAccessKey(account);
    expect(bound.isBound, true);
    expect(bound.value, isNull);
    // The legacy nullable wrapper and accessKeyOf cannot distinguish a bound
    // null from an absent credential; the tagged API is the distinction.
    expect(Accounts.accessKeyOf(account), isNull);
    final tagged = accountCredentialReader.boundAccessKeyFor(
      account,
      Accounts.captureRequest(account)!,
    );
    expect(tagged.isBound, true);
    expect(tagged.value, isNull);
  });

  test('a rejected stamp never falls back to the raw access key', () async {
    final account = _account(960008);
    await Accounts.installCredentials(account);
    const denied = DeniedCredentialReader();
    final bound = Accounts.boundAccessKey(account, reader: denied);
    expect(bound.isRejected, true);
    expect(bound.value, isNull);
    expect(Accounts.accessKeyOf(account, reader: denied), isNull);
    expect(account.accessKey, 'access-960008');
  });

  test('a stamp retained across an await is rejected after the owner is replaced', () async {
    final account = _account(960009);
    await Accounts.installCredentials(account);
    final stamp = Accounts.captureRequest(account)!;
    await Future<void>.delayed(Duration.zero);
    await Accounts.installCredentials(_account(960009));
    expect(
      accountCredentialReader.boundAccessKeyFor(account, stamp).isRejected,
      true,
    );
    expect(
      accountCredentialReader.boundCsrfFor(account, stamp).isRejected,
      true,
    );
    // The retired owner is not resurrected by the legacy wrapper either.
    expect(Accounts.accessKeyOf(account), isNull);
  });
}
