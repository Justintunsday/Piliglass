import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

/// Separate Flutter test isolate: Accounts.account is static late final.
void main() {
  test('uninitialized capture is unavailable before anonymous Pref initialization', () {
    expect(Accounts.captureLiveMemoryShadow,
      throwsA(isA<AccountLiveMemoryShadowException>().having((e) => e.code, 'code', 'unavailable')));
  });

  test('actual Hive reopen retains cold order and does not activate unregistered anonymous', () async {
    final originals = [for (final key in ['2', '10']) LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': key, 'bili_jct': 'synthetic-cold-csrf',
        'SESSDATA': 'synthetic-cold-session'}),
      'synthetic-cold-access', 'synthetic-cold-refresh', {AccountType.video},
    )..activated = true];
    final storage = await AccountTestStorage.open(initialAccounts: originals);
    try {
      final restored = Accounts.account.values.toList();
      expect(restored.map((a) => a.storageKey), ['10', '2']);
      expect(restored.every((a) => !a.activated), true);
      for (final original in originals) {
        expect(Accounts.captureRequest(original), isNull);
      }
      final revision = Accounts.requestRevision;
      expect(Accounts.captureLiveMemoryShadow,
        throwsA(isA<AccountLiveMemoryShadowException>().having((e) => e.code, 'code', 'unavailable')));
      expect(Accounts.requestRevision, revision);
      // Normal lifecycle supplies the anonymous generation; capture itself does not.
      AnonymousAccount().activated = true;
      Accounts.captureRequest(AnonymousAccount());
      final capture = Accounts.captureLiveMemoryShadow();
      String key(dynamic entry) => String.fromCharCodes(
        ((entry as Map)['keyUnits'] as List).cast<int>());
      expect((capture.value['storedOrder'] as List).map(key), ['10', '2']);
      expect((capture.value['ownerOrder'] as List).map(key), ['10', '2']);
      expect(capture.value['selections'], [0, 0, 0, 0]);
      expect(capture.value['history'], 0);
      capture.verifyCurrent();
    } finally {
      await storage.close();
    }
  });
}
