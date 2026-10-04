import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/native_account_snapshot_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

void main() {
  late AccountTestStorage storage;
  late LoginAccount initial;
  setUpAll(() async {
    initial = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '601', 'bili_jct': 'synthetic-hive-csrf', 'SESSDATA': 'synthetic-hive-session'}),
      'synthetic-hive-access', 'synthetic-hive-refresh', {AccountType.video},
    );
    await initial.cookieJar.saveFromResponse(Uri.parse('https://api.bilibili.com/x/test'), [
      Cookie('root_metadata', 'lost-metadata')..domain = '.bilibili.com'..path = '/'
        ..secure = true..httpOnly = true..maxAge = 900,
      Cookie('nested_lost', 'not-in-hive')..domain = '.bilibili.com'..path = '/x',
      Cookie('host_lost', 'not-in-hive')..path = '/',
    ]);
    storage = await AccountTestStorage.open(initialAccounts: [initial]);
  });
  tearDownAll(() => storage.close());

  test('actual Hive reopen preserves credentials and marks lost attributes honestly', () async {
    final restored = Accounts.account.get('601')!;
    expect(restored, isNot(same(initial)));
    expect(restored.cookieJar.toJson()['root_metadata'], 'lost-metadata');
    expect(restored.cookieJar.toJson().containsKey('nested_lost'), false);
    expect(restored.cookieJar.hostCookies, isEmpty);
    restored.activated = true;
    AnonymousAccount().activated = true;
    await Accounts.refresh();
    final export = await NativeAccountSnapshotService().stagingExport();
    final entries = (export['entries'] as List).cast<Map>();
    final entry = entries.firstWhere((e) => e['accessKey'] == 'synthetic-hive-access');
    expect(entry['legacyHiveAttributesIncomplete'], true);
    final root = (entry['cookies'] as List).cast<Map>().firstWhere((c) => c['name'] == 'root_metadata');
    expect(root['secure'], false);
    expect(root['httpOnly'], false);
    expect(root['maxAgeSeconds'], null);
    expect(entry['refreshToken'], 'synthetic-hive-refresh');
    final directory = Directory('build/native-account-contracts');
    await directory.create(recursive: true);
    await File('${directory.path}/hive-reopened.json').writeAsString(jsonEncode(export));
  });
}
