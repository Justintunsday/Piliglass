import 'dart:convert';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/native_account_reverse_import.dart';
import 'package:PiliPlus/services/native_accounts/native_ordered_cookie_jar_export.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';
import 'native_account_envelope_fixtures.dart';

String? _units(Object? value) => value == null
    ? null
    : String.fromCharCodes((value as List).cast<int>());

void main() {
  late AccountTestStorage storage;
  setUpAll(() async { storage = await AccountTestStorage.open(); });
  setUp(() => storage.reset());
  tearDownAll(() => storage.close());

  test('reverse import reconstructs captured jars, order, credentials, purposes and selections', () async {
    final first = envelopeFixtureAccount('2', purposes: {AccountType.video});
    addEnvelopeFixtureAttributes(first.cookieJar);
    final second = envelopeFixtureAccount('10', purposes: {AccountType.main});
    await Accounts.installCredentials(first);
    await Accounts.installCredentials(second);
    await Accounts.refresh();
    Accounts.selectTemporarily(AccountType.heartbeat, first);
    final capture = Accounts.captureLiveMemoryShadow().value;
    final records = (capture['records']! as List).cast<Map>();
    final expectedJars = [
      for (final record in records.skip(1)) jsonEncode(record['jar']),
    ];
    final expectedKeys = [
      for (final record in records.skip(1)) _units(record['storageKeyUnits'])!,
    ];
    final expectedSelections = (capture['selections']! as List).cast<int>();
    final expectedHistory = capture['history']! as int;

    final decoded = NativeAccountReverseImport.decode(capture);
    expect(decoded.accountKeys, ['10', '2']);

    await Accounts.clear();
    await NativeAccountReverseImportService().apply(decoded);
    final restored = Accounts.account.toMap();
    expect(restored.keys.toList(), expectedKeys);
    final restoredAccounts = restored.values.toList();
    for (var index = 0; index < restoredAccounts.length; index++) {
      final account = restoredAccounts[index];
      final record = records[index + 1];
      expect(account.storageKey, expectedKeys[index]);
      expect(jsonEncode(NativeOrderedCookieJarExporter.export(account.cookieJar)),
        expectedJars[index]);
      expect(account.accessKey, _units(record['accessKeyUnits']));
      expect(account.refresh, _units(record['refreshTokenUnits']));
      expect(account.activated, record['activated']);
      expect(
        account.type,
        {
          for (final name in (record['persistedPurposes']! as List))
            AccountType.values.firstWhere((type) => type.name == name),
        },
      );
    }
    int ordinalOf(Account value) {
      if (value is! LoginAccount) return 0;
      final index = restoredAccounts.indexWhere((candidate) => identical(candidate, value));
      expect(index, isNot(-1));
      return index + 1;
    }
    expect([for (final account in Accounts.accountMode) ordinalOf(account)], expectedSelections);
    expect(ordinalOf(Accounts.history), expectedHistory);
  });

  test('reverse import rejects malformed or incomplete captures without touching live accounts', () async {
    final account = envelopeFixtureAccount('777');
    await Accounts.installCredentials(account);
    final before = Accounts.account.toMap();
    final capture = Accounts.captureLiveMemoryShadow().value;

    final wrongSchema = Map<String, Object?>.of(capture)..['schemaVersion'] = 1;
    expect(() => NativeAccountReverseImport.decode(wrongSchema),
      throwsA(isA<NativeAccountReverseImportException>()));

    final wrongSelections = Map<String, Object?>.of(capture)..['selections'] = [0, 0, 0];
    expect(() => NativeAccountReverseImport.decode(wrongSelections),
      throwsA(isA<NativeAccountReverseImportException>()));

    final mutated = jsonDecode(jsonEncode(capture)) as Map<String, Object?>;
    final records = (mutated['records']! as List).cast<Map>();
    final jars = (records[1]['jar']! as Map).cast<String, Object?>();
    final buckets = (jars['domainBuckets']! as List).cast<Map>();
    final paths = (buckets.first['paths']! as List).cast<Map>();
    final cookies = (paths.first['cookies']! as List).cast<Map>()
      ..removeWhere((cookie) => _units(cookie['nameUnits']) == 'DedeUserID');
    expect(() => NativeAccountReverseImport.decode(mutated),
      throwsA(isA<NativeAccountReverseImportException>()
        .having((error) => error.code, 'code', 'missingCapturedIdentity')));

    expect(Accounts.account.toMap(), before);
  });
}
