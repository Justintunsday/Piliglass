import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/account_reset_persistence_port.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'account_test_storage.dart';

LoginAccount _account(String key) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': key,
    'bili_jct': 'synthetic-reset-csrf',
    'SESSDATA': 'synthetic-reset-session-$key',
  }),
  'synthetic-reset-access',
  'synthetic-reset-refresh',
)..activated = true;

void _addAnonymousCookies(AnonymousAccount anonymous) {
  anonymous.cookieJar
    ..domainCookies['bilibili.com']!['/']!['synthetic-reset'] = SerializableCookie(
      Cookie('synthetic-reset', 'synthetic-domain'),
    )
    ..hostCookies['api.bilibili.com'] = {
      '/': {
        'synthetic-host': SerializableCookie(
          Cookie('synthetic-host', 'synthetic-host-value'),
        ),
      },
    };
}

void main() {
  late AccountTestStorage storage;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });
  setUp(() => storage.reset());
  tearDownAll(() => storage.close());

  test('default port preserves real Hive clear count and empty reopen', () async {
    final box = await Hive.openBox<LoginAccount>('reset-port-clear');
    await box.putAll({'02': _account('02'), '2': _account('2')});
    expect(box.length, 2);
    final revision = Accounts.requestRevision;

    // The actual Hive clear awaits its backend before clearing the keystore.
    // Deliberately make no assertion that the box is empty before awaiting.
    final clearing = accountResetPersistencePort.clearLegacyAccounts(box);
    expect(await clearing, 2);
    expect(box.isEmpty, isTrue);
    expect(Accounts.requestRevision, revision);
    await box.close();
    final reopened = await Hive.openBox<LoginAccount>('reset-port-clear');
    try {
      expect(reopened.isEmpty, isTrue);
    } finally {
      await reopened.close();
    }
  });

  test('anonymous forwarding clears real maps without lifecycle side effects', () async {
    final anonymous = AnonymousAccount();
    _addAnonymousCookies(anonymous);
    final stamp = Accounts.captureRequest(anonymous)!;
    final revision = Accounts.requestRevision;
    final headers = Map<String, String>.of(anonymous.grpcHeaders);
    final activated = anonymous.activated;

    final clearing = accountResetPersistencePort.clearAnonymousCookies(anonymous);
    expect(anonymous.cookieJar.domainCookies, isEmpty);
    expect(anonymous.cookieJar.hostCookies, isEmpty);
    expect(Accounts.requestRevision, revision);
    expect(Accounts.captureRequest(anonymous), same(stamp));
    expect(anonymous.activated, activated);
    expect(anonymous.grpcHeaders, headers);
    await clearing;
    expect(anonymous.cookieJar.domainCookies, isEmpty);
    expect(Accounts.captureRequest(anonymous), same(stamp));
    expect(Accounts.requestRevision, revision);
  });

  test('real anonymous reset stays busy until completion and restores only buvid', () async {
    final anonymous = AnonymousAccount();
    _addAnonymousCookies(anonymous);
    final stamp = Accounts.captureRequest(anonymous)!;
    final revision = Accounts.requestRevision;
    final originalFawkes = anonymous.grpcHeaders['x-bili-fawkes-req-bin'];

    // The new forwarding must accept this already-revoked resetting owner.
    final resetting = anonymous.delete();
    expect(Accounts.isCurrentRequest(stamp), isFalse);
    expect(Accounts.captureRequest(anonymous), isNull);
    expect(Accounts.captureLiveMemoryShadow,
      throwsA(isA<AccountLiveMemoryShadowException>().having(
        (error) => error.code, 'code', 'busy',
      )));
    expect(anonymous.activated, isFalse);
    expect(anonymous.grpcHeaders['x-bili-fawkes-req-bin'], isNot(originalFawkes));
    expect(anonymous.cookieJar.domainCookies, isEmpty);
    expect(anonymous.cookieJar.hostCookies, isEmpty);
    expect(Accounts.requestRevision, greaterThan(revision));

    await resetting;
    final successor = Accounts.captureRequest(anonymous)!;
    expect(AnonymousAccount(), same(anonymous));
    expect(successor, isNot(same(stamp)));
    expect(Accounts.isCurrentRequest(successor), isTrue);
    expect(Accounts.isCurrentRequest(stamp), isFalse);
    expect(anonymous.activated, isFalse);
    expect(anonymous.cookieJar.domainCookies.keys, ['bilibili.com']);
    expect(anonymous.cookieJar.domainCookies['bilibili.com']!.keys, ['/']);
    expect(anonymous.cookieJar.domainCookies['bilibili.com']!['/']!.keys, ['buvid3']);
    expect(anonymous.cookieJar.toJson()['buvid3'], isNotEmpty);
    expect(anonymous.cookieJar.hostCookies, isEmpty);
    Accounts.captureLiveMemoryShadow().verifyCurrent();
  });

  test('Accounts clear revokes selections before real persistence completion', () async {
    final owner = _account('830001');
    await Accounts.installCredentials(owner);
    await Accounts.set(AccountType.recommend, owner);
    final stamp = Accounts.captureRequest(owner)!;
    final anonymous = AnonymousAccount();
    final anonymousStamp = Accounts.captureRequest(anonymous)!;
    _addAnonymousCookies(anonymous);
    final persistedTypes = Set<AccountType>.of(owner.type);

    final clearing = Accounts.clear();
    expect(Accounts.isCurrentRequest(stamp), isFalse);
    expect(Accounts.isCurrentRequest(anonymousStamp), isFalse);
    expect(Accounts.captureRequest(owner), isNull);
    expect(Accounts.captureRequest(anonymous), isNull);
    expect(Accounts.accountMode.every((value) => identical(value, anonymous)), isTrue);
    expect(anonymous.cookieJar.domainCookies, isEmpty);
    expect(anonymous.cookieJar.hostCookies, isEmpty);
    // clear removes stored credentials, rather than invoking each login's delete.
    expect(owner.cookieJar.toJson()['SESSDATA'], 'synthetic-reset-session-830001');
    expect(owner.type, persistedTypes);

    await clearing;
    expect(Accounts.account.isEmpty, isTrue);
    expect(Accounts.captureRequest(owner), isNull);
    expect(owner.onChange(), isNull);
    final successor = Accounts.captureRequest(anonymous)!;
    expect(successor, isNot(same(anonymousStamp)));
    expect(Accounts.isCurrentRequest(successor), isTrue);
    expect(Accounts.isCurrentRequest(anonymousStamp), isFalse);
    expect(anonymous.cookieJar.toJson()['buvid3'], isNotEmpty);
    expect(Accounts.accountMode.every((value) => identical(value, anonymous)), isTrue);
    // The legacy clear's activation is fire-and-forget; no remote success claim.
  });
}
