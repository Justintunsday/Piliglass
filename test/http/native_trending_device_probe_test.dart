import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_http/native_trending_device_probe.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import '../utils/accounts/account_test_storage.dart';

void main() {
  test(
    'device probe verifies and restores all three owner transitions',
    () async {
      final storage = await AccountTestStorage.open(replaceHTTPAdapter: false);
      addTearDown(storage.close);
      final login = LoginAccount(
        BiliCookieJar.fromJson({'DedeUserID': '74001', 'SESSDATA': 'fixture'}),
        null,
        null,
      )..activated = true;
      await Accounts.installCredentials(login);
      Accounts.selectTemporarily(AccountType.main, login);
      Accounts.selectTemporarily(AccountType.recommend, login);
      final probe = NativeTrendingDeviceProbe();
      addTearDown(probe.requests.dispose);

      for (final (index, phase) in ['split', 'switch', 'revoke'].indexed) {
        String command(String value) =>
            probe.command({'phase': value}) as String;
        expect(command(phase), 'armed');
        expect(Accounts.get(AccountType.recommend), isA<AnonymousAccount>());
        final requestID = 'a5400000-0000-4000-8000-00000000000${index + 1}';
        final prepared = await probe.handleLease('prepareNativeHTTPRequest', {
          'requestID': requestID,
          'purpose': 'searchTrending',
          'limit': 10,
        });
        expect(prepared['state'], 'prepared');
        expect(command('head'), 'checkpoint');
        final revoked = phase == 'revoke';
        final receipt = await probe.handleLease('finishNativeHTTPRequest', {
          'requestID': requestID,
          'leaseID': prepared['leaseID'],
          'response': {
            'url': prepared['url'],
            'statusCode': 200,
            'cookieSource': 'separatedFields',
            'setCookieValues': <String>[],
          },
        });
        expect(receipt['state'], revoked ? 'revoked' : 'finished');
        expect(probe.command({'phase': 'end'}), {
          'receipt': revoked ? 'revoked' : 'finished',
          'cookiesSaved': !revoked,
          'cookieCount': revoked ? 0 : 1,
          'heads': 1,
          'writeBacks': revoked ? 0 : 1,
          'guestOnly': true,
          'leaseReleased': true,
          'accountRestored': true,
        });
        expect(Accounts.get(AccountType.recommend), same(login));
        final endpoint = Uri.parse(prepared['url'] as String);
        for (final account in [login, AnonymousAccount()]) {
          final cookies = await account.cookieJar.loadForRequest(endpoint);
          expect(
            cookies.any(
              (cookie) =>
                  cookie.name == 'piliglass_trending_device_acceptance_canary',
            ),
            isFalse,
          );
        }
      }
    },
  );
}
