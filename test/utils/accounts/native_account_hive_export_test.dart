import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/native_account_snapshot_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_credential_reader_fixtures.dart';
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

  test('a denied credential reader fails the staging export closed and the default reader keeps bound values', () async {
    Accounts.account.get('601')!..activated = true;
    AnonymousAccount().activated = true;
    await Accounts.refresh();
    final denied = NativeAccountSnapshotService(
      credentialReader: const DeniedCredentialReader(),
    );
    await expectLater(
      denied.stagingExport(),
      throwsA(isA<NativeAccountSnapshotException>().having(
        (error) => error.code, 'code', 'snapshotChanged')),
    );
    final export = await NativeAccountSnapshotService().stagingExport();
    final entries = (export['entries'] as List).cast<Map>();
    final entry = entries.firstWhere((e) => e['accessKey'] == 'synthetic-hive-access');
    expect(entry['refreshToken'], 'synthetic-hive-refresh');
  });

  test('staging entry rejects a refresh-only denial after descriptors were accepted', () async {
    Accounts.account.get('601')!..activated = true;
    AnonymousAccount().activated = true;
    await Accounts.refresh();
    final scripted = ScriptedCredentialReader(boundRefreshAllowance: 2);
    final service = NativeAccountSnapshotService(credentialReader: scripted);
    final revision = Accounts.requestRevision;
    await expectLater(
      service.stagingExport(),
      throwsA(isA<NativeAccountSnapshotException>().having(
        (error) => error.code, 'code', 'snapshotChanged')),
    );
    // Two descriptor reads were accepted (anonymous + 601); the third refresh
    // read is the first staging-entry secret read and was rejected, so no
    // partial wire was returned and the access key stayed bound.
    expect(scripted.boundRefreshReads, 3);
    expect(scripted.boundAccessKeyReads, 3);
    expect(Accounts.requestRevision, revision);
    final export = await NativeAccountSnapshotService().stagingExport();
    final entries = (export['entries'] as List).cast<Map>();
    final entry = entries.firstWhere((e) => e['accessKey'] == 'synthetic-hive-access');
    expect(entry['refreshToken'], 'synthetic-hive-refresh');
  });

  test('staging entry rejects an access-key-only denial after descriptors were accepted', () async {
    Accounts.account.get('601')!..activated = true;
    AnonymousAccount().activated = true;
    await Accounts.refresh();
    final scripted = ScriptedCredentialReader(boundAccessKeyAllowance: 2);
    final service = NativeAccountSnapshotService(credentialReader: scripted);
    final revision = Accounts.requestRevision;
    await expectLater(
      service.stagingExport(),
      throwsA(isA<NativeAccountSnapshotException>().having(
        (error) => error.code, 'code', 'snapshotChanged')),
    );
    expect(scripted.boundAccessKeyReads, 3);
    expect(scripted.boundRefreshReads, 2);
    expect(Accounts.requestRevision, revision);
  });

  test('post-checkpoint verification uses the same reader and fails closed on a stateful denial', () async {
    Accounts.account.get('601')!..activated = true;
    AnonymousAccount().activated = true;
    await Accounts.refresh();
    final scripted = ScriptedCredentialReader();
    final service = NativeAccountSnapshotService(
      checkpoint: () async {
        scripted.denyRefresh = true;
      },
      credentialReader: scripted,
    );
    final revision = Accounts.requestRevision;
    await expectLater(
      service.stagingExport(),
      throwsA(isA<NativeAccountSnapshotException>().having(
        (error) => error.code, 'code', 'snapshotChanged')),
    );
    // Descriptors and entries ran bound (four reads); the fifth refresh read
    // is the post-checkpoint `_verify` recapture and was rejected.
    expect(scripted.boundRefreshReads, 5);
    expect(scripted.boundAccessKeyReads, 5);
    expect(Accounts.requestRevision, revision);
  });
}
