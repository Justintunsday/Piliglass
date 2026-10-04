import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

LoginAccount _account() => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '123',
    'bili_jct': 'csrf',
  }),
  'access-key',
  'refresh-token',
);

void main() {
  late AccountTestStorage storage;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });

  setUp(() => storage.reset());

  tearDownAll(() async {
    await storage.close();
  });

  test('late account changes cannot recreate a deleted account', () async {
    final account = _account();
    await Accounts.installCredentials(account);
    expect(Accounts.account.containsKey('123'), isTrue);

    final lateResponse = Completer<void>();
    final persistLateResponse = lateResponse.future.then((_) async {
      await account.cookieJar.saveFromResponse(
        Uri.parse('https://www.bilibili.com'),
        [Cookie('SESSDATA', 'late-cookie')..setBiliDomain()],
      );
      await account.onChange();
    });

    await account.delete();
    lateResponse.complete();
    await persistLateResponse;

    expect(Accounts.account.containsKey('123'), isFalse);
  });

  test(
    'delete tombstone is active before asynchronous deletion completes',
    () async {
      final account = _account();
      await Accounts.installCredentials(account);

      final deletion = account.delete();
      await account.onChange();
      await deletion;

      expect(Accounts.account.containsKey('123'), isFalse);
    },
  );
}
