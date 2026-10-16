import 'package:PiliPlus/services/native_accounts/account_credential_reader.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_credential_reader_fixtures.dart';
import 'account_test_storage.dart';

LoginAccount _account(int mid, {bool withRefresh = true}) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'csrf-$mid',
    'SESSDATA': 'session-$mid',
  }),
  'access-$mid',
  withRefresh ? 'refresh-$mid' : null,
)..activated = true;

void main() {
  late AccountTestStorage storage;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });
  setUp(() => storage.reset());
  tearDownAll(() => storage.close());

  test('refreshOf returns the real value for an installed owner', () async {
    final account = _account(970001);
    await Accounts.installCredentials(account);
    expect(Accounts.refreshOf(account), 'refresh-970001');
  });

  test('refreshOf routes the installed owner through the credential reader with zero side effects', () async {
    final account = _account(970002);
    await Accounts.installCredentials(account);
    final counter = CountingCredentialReader();
    final revision = Accounts.requestRevision;
    expect(Accounts.refreshOf(account, reader: counter), 'refresh-970002');
    expect(counter.refreshReads, 1);
    expect(counter.captures, 0);
    expect(counter.csrfReads, 0);
    expect(counter.accessKeyReads, 0);
    expect(Accounts.requestRevision, revision);
  });

  test('refreshOf falls back to the direct field for an uninstalled owner', () {
    final account = _account(970003);
    expect(Accounts.refreshOf(account), 'refresh-970003');
  });

  test('boundRefresh is tagged: bound, not installed, and legacy refreshOf rules', () async {
    final account = _account(970004);
    await Accounts.installCredentials(account);
    final counter = CountingCredentialReader();
    final bound = Accounts.boundRefresh(account, reader: counter);
    expect(bound.isBound, true);
    expect(bound.value, 'refresh-970004');
    expect(counter.boundRefreshReads, 1);
    expect(Accounts.boundRefresh(_account(970005)).isNotInstalled, true);
    await account.delete();
    expect(Accounts.boundRefresh(account).isNotInstalled, true);
    expect(counter.boundRefreshReads, 1);
    // A retired owner must not fall back to its stale direct field.
    expect(Accounts.refreshOf(account), isNull);
    // Uninstalled owners keep the legacy compatibility read.
    expect(Accounts.refreshOf(_account(970006)), 'refresh-970006');
  });

  test('a bound null refresh token is data, not a rejection', () async {
    final account = _account(970007, withRefresh: false);
    await Accounts.installCredentials(account);
    final bound = Accounts.boundRefresh(account);
    expect(bound.isBound, true);
    expect(bound.value, isNull);
    // The legacy nullable wrapper and refreshOf cannot distinguish a bound
    // null from an absent credential; the tagged API is the distinction.
    expect(Accounts.refreshOf(account), isNull);
    final tagged = accountCredentialReader.boundRefreshFor(
      account,
      Accounts.captureRequest(account)!,
    );
    expect(tagged.isBound, true);
    expect(tagged.value, isNull);
  });

  test('a rejected stamp never falls back to the raw refresh token', () async {
    final account = _account(970008);
    await Accounts.installCredentials(account);
    const denied = DeniedCredentialReader();
    final bound = Accounts.boundRefresh(account, reader: denied);
    expect(bound.isRejected, true);
    expect(bound.value, isNull);
    expect(Accounts.refreshOf(account, reader: denied), isNull);
    expect(account.refresh, 'refresh-970008');
  });

  test('a stamp retained across an await is rejected after the owner is replaced', () async {
    final account = _account(970009);
    await Accounts.installCredentials(account);
    final stamp = Accounts.captureRequest(account)!;
    await Future<void>.delayed(Duration.zero);
    await Accounts.installCredentials(_account(970009));
    expect(
      accountCredentialReader.boundRefreshFor(account, stamp).isRejected,
      true,
    );
    expect(
      accountCredentialReader.boundAccessKeyFor(account, stamp).isRejected,
      true,
    );
    // The retired owner is not resurrected by the legacy wrapper either.
    expect(Accounts.refreshOf(account), isNull);
  });
}
