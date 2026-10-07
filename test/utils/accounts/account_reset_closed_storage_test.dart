import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'account_test_storage.dart';

// This file gets its own isolate: Accounts.account is late final and remains
// closed after this rejection. Do not fold this into a shared reset/setUp suite.
void main() {
  test('closed real Hive clear preserves error and completed anonymous reset', () async {
    final storage = await AccountTestStorage.open();
    try {
      await storage.reset();
      final owner = LoginAccount(
        BiliCookieJar.fromJson({
          'DedeUserID': '830002',
          'bili_jct': 'synthetic-closed-reset-csrf',
          'SESSDATA': 'synthetic-closed-reset-session',
        }),
        'synthetic-closed-reset-access',
        'synthetic-closed-reset-refresh',
      )..activated = true;
      await Accounts.installCredentials(owner);
      final stamp = Accounts.captureRequest(owner)!;
      final anonymous = AnonymousAccount();
      final anonymousStamp = Accounts.captureRequest(anonymous)!;
      await Accounts.account.close();

      // Real Hive rejects clear on its closed Box. The anonymous branch has
      // already begun; Future.wait still observes its completion before failure.
      final clearing = Accounts.clear();
      expect(Accounts.captureRequest(owner), isNull);
      expect(Accounts.isCurrentRequest(stamp), isFalse);
      expect(Accounts.captureRequest(anonymous), isNull);
      expect(anonymous.activated, isFalse);
      expect(anonymous.cookieJar.domainCookies, isEmpty);
      expect(anonymous.cookieJar.hostCookies, isEmpty);

      final failure = await clearing.then<Object>(
        (_) => throw StateError('Expected closed real Hive clear to fail'),
        onError: (Object error, StackTrace stack) => error,
      );
      expect(failure, isA<HiveError>());
      await expectLater(clearing, throwsA(same(failure)));
      expect(Accounts.account.isOpen, isFalse);
      expect(Accounts.captureRequest(owner), isNull);
      expect(owner.onChange(), isNull);
      expect(Accounts.isCurrentRequest(stamp), isFalse);
      expect(Accounts.isCurrentRequest(anonymousStamp), isFalse);
      final successor = Accounts.captureRequest(anonymous)!;
      expect(successor, isNot(same(anonymousStamp)));
      expect(Accounts.isCurrentRequest(successor), isTrue);
      expect(anonymous.cookieJar.toJson()['buvid3'], isNotEmpty);
      // clear threw before its activation call; reset alone does not activate.
      expect(anonymous.activated, isFalse);

      // The failed clear was rejected before backend access: the actual prior
      // Hive record survives reopen, but its runtime request stamp stays revoked.
      final reopened = await Hive.openBox<LoginAccount>('account');
      try {
        final restored = reopened.get('830002')!;
        expect(restored.cookieJar.toJson()['SESSDATA'], 'synthetic-closed-reset-session');
        expect(Accounts.captureRequest(restored), isNull);
        expect(Accounts.isCurrentRequest(stamp), isFalse);
      } finally {
        await reopened.close();
      }
    } finally {
      await storage.close();
    }
  });
}
