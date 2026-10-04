import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

void main() {
  late AccountTestStorage storage;
  late LoginAccount initial;

  setUpAll(() async {
    initial = LoginAccount(
      BiliCookieJar.fromJson({
        'DedeUserID': '303',
        'bili_jct': 'stored-csrf',
        'SESSDATA': 'stored-session',
      }),
      'stored-access-key',
      'stored-refresh-token',
      {AccountType.video},
    );
    storage = await AccountTestStorage.open(initialAccounts: [initial]);
  });

  tearDownAll(() => storage.close());

  test('init registers deserialized accounts before they are selected', () async {
    final restored = Accounts.account.get('303')!;
    expect(restored, isNot(same(initial)));
    expect(restored.cookieJar, isNot(same(initial.cookieJar)));
    expect(restored.cookieJar.toJson()['SESSDATA'], 'stored-session');
    expect(restored.accessKey, 'stored-access-key');
    expect(restored.refresh, 'stored-refresh-token');
    expect(restored.type, {AccountType.video});
    expect(Accounts.ownsCredentials(restored), isTrue);
    expect(Accounts.captureRequest(initial), isNull);
    expect(Accounts.get(AccountType.video), isA<AnonymousAccount>());
    final stamp = Accounts.captureRequest(restored)!;
    restored.activated = true;
    AnonymousAccount().activated = true;

    await Accounts.refresh();
    expect(Accounts.get(AccountType.video), same(restored));
    expect(Accounts.isCurrentRequest(stamp), isTrue);
    await Accounts.refresh();
    expect(Accounts.isCurrentRequest(stamp), isTrue);
  });
}
