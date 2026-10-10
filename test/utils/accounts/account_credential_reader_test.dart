import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/account_credential_reader.dart';
import 'package:PiliPlus/services/native_http/native_http_request_lease_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/accounts/account_request_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

LoginAccount _account(int mid, {String session = 'reader', String csrf = 'csrf'}) =>
    LoginAccount(
      BiliCookieJar.fromJson({
        'DedeUserID': '$mid',
        'bili_jct': csrf,
        'SESSDATA': session,
      }),
      'access-$session',
      'refresh-$session',
    )..activated = true;

void main() {
  late AccountTestStorage storage;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });
  setUp(() => storage.reset());
  tearDownAll(() => storage.close());

  test('captureRequest returns an owned immutable snapshot of the bound owner', () async {
    final account = _account(930001, session: 'reader', csrf: 'csrf-930001');
    await Accounts.installCredentials(account);
    final stamp = Accounts.captureRequest(account)!;
    final revision = Accounts.requestRevision;

    final context = accountCredentialReader.captureRequest(account, stamp);
    expect(context, isNotNull);
    expect(context!.mid, 930001);
    expect(context.isLogin, true);
    expect(context.activated, true);
    expect(context.generation, stamp.generation);
    expect(context.accessKey, 'access-reader');
    expect(context.headers['x-bili-mid'], '930001');
    expect(context.grpcHeaders, isNotEmpty);
    expect(Accounts.requestRevision, revision);
    expect(() => context.headers['x'] = 'y', throwsUnsupportedError);
    expect(() => context.grpcHeaders['x'] = 'y', throwsUnsupportedError);

    account.headers['reader_after'] = 'later';
    expect(context.headers.containsKey('reader_after'), false);
    final again = accountCredentialReader.captureRequest(account, stamp);
    expect(again!.headers['reader_after'], 'later');
  });

  test('revoked replacement and foreign stamps return null without live fallback', () async {
    final old = _account(930002, session: 'old');
    await Accounts.installCredentials(old);
    final stamp = Accounts.captureRequest(old)!;
    final successor = _account(930002, session: 'new');
    await Accounts.installCredentials(successor);
    expect(accountCredentialReader.captureRequest(old, stamp), isNull);
    expect(accountCredentialReader.captureRequest(successor, stamp), isNull);
    expect(accountCredentialReader.csrfFor(old, stamp), isNull);

    final anonymous = AnonymousAccount();
    final foreignState = AccountRequestState<Account>();
    final foreign = foreignState.activate(anonymous);
    final revision = Accounts.requestRevision;
    expect(accountCredentialReader.captureRequest(anonymous, foreign), isNull);
    expect(accountCredentialReader.csrfFor(anonymous, foreign), isNull);
    expect(Accounts.requestRevision, revision);
  });

  test('ordinary selection changes do not revoke the original owner context', () async {
    final a = _account(930003, session: 'a');
    final b = _account(930004, session: 'b');
    await Accounts.installCredentials(a);
    await Accounts.installCredentials(b);
    await Accounts.set(AccountType.recommend, a);
    final stamp = Accounts.captureRequest(a)!;
    await Accounts.set(AccountType.recommend, b);

    final context = accountCredentialReader.captureRequest(a, stamp);
    expect(context, isNotNull);
    expect(context!.mid, 930003);
    expect(accountCredentialReader.captureRequest(b, stamp), isNull);
  });

  test('csrfFor reads the real value and goes null after owner deletion', () async {
    final account = _account(930005, csrf: 'csrf-real-930005');
    await Accounts.installCredentials(account);
    final stamp = Accounts.captureRequest(account)!;
    expect(accountCredentialReader.csrfFor(account, stamp), 'csrf-real-930005');
    await account.delete();
    expect(accountCredentialReader.csrfFor(account, stamp), isNull);
  });

  test('accessKeyFor follows the same bound-owner rule', () async {
    final account = _account(930006, session: 'key');
    await Accounts.installCredentials(account);
    final stamp = Accounts.captureRequest(account)!;
    expect(accountCredentialReader.accessKeyFor(account, stamp), 'access-key');
    final successor = _account(930006, session: 'new');
    await Accounts.installCredentials(successor);
    expect(accountCredentialReader.accessKeyFor(account, stamp), isNull);
  });

  test('visibleAccounts returns read-only summaries matching the real box', () async {
    await Accounts.installCredentials(_account(930011));
    await Accounts.installCredentials(_account(930012));
    final summaries = accountCredentialReader.visibleAccounts();
    expect(
      [for (final summary in summaries) summary.storageKey],
      ['930011', '930012'],
    );
    expect([for (final summary in summaries) summary.mid], [930011, 930012]);
    expect(
      summaries.every((summary) => summary.isLogin && summary.activated),
      true,
    );
    expect(
      () => summaries.add(
        const AccountCredentialSummary(
          storageKey: 'x',
          mid: 1,
          isLogin: true,
          activated: false,
        ),
      ),
      throwsUnsupportedError,
    );
    expect(Accounts.account.isNotEmpty, true);
  });

  test('production composition shares one read-only credential reader', () {
    expect(
      identical(AccountManager().credentialReader, accountCredentialReader),
      true,
    );
    expect(
      identical(
        NativeHTTPRequestLeaseService(autoExpire: false).credentialReader,
        accountCredentialReader,
      ),
      true,
    );
    expect(
      identical(
        AccountManager().credentialReader,
        NativeHTTPRequestLeaseService(autoExpire: false).credentialReader,
      ),
      true,
    );
  });
}
