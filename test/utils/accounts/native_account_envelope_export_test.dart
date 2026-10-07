import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/native_account_live_memory_capture.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';
import 'native_account_envelope_fixtures.dart';

void main() {
  late AccountTestStorage storage;
  final cases = <Map<String, Object?>>[];
  const expectedIDs = [
    'anonymous-empty-jar',
    'stored-10-2-owner-2-10',
    'same-key-replacement-owner-10-2',
    'distinct-raw-02-and-2-equal-mid',
    'zero-and-negative-login-mid',
    'four-effective-purposes',
    'temporary-heartbeat-anonymous-history-main',
    'anonymous-persisted-purposes',
    'raw-utf16-full-attributes-nullable-credentials',
  ];

  Future<void> record(String id) async {
    final revision = Accounts.requestRevision;
    final started = DateTime.now().microsecondsSinceEpoch;
    // The JSON oracle is the production service's exact owned payload. Never
    // rebuild records, reorder keys, recalculate selections or replace times.
    final envelope = await NativeAccountLiveMemoryCaptureService().capture();
    final finished = DateTime.now().microsecondsSinceEpoch;
    expect(Accounts.requestRevision, revision);
    expect(envelope['nativeWritesAllowed'], false);
    expect(envelope['authoritySwitchAllowed'], false);
    expect(envelope['durabilityVerified'], false);
    cases.add({
      'id': id,
      'captureStartedMicroseconds': started,
      'captureFinishedMicroseconds': finished,
      'envelope': envelope,
    });
  }

  setUpAll(() async { storage = await AccountTestStorage.open(); });
  setUp(() async {
    await storage.reset();
    // Anonymous reset does not clear this mutable legacy field. Each case
    // explicitly supplies its source fixture state, without faking stamps.
    AnonymousAccount().type.clear();
  });
  tearDownAll(() async {
    try {
      // A failed or partial case set cannot produce a usable golden archive.
      expect(cases.map((entry) => entry['id']).toList(), expectedIDs);
      final file = File('build/native-account-envelope-check/live-memory.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'schemaVersion': 1,
        'source': 'actual Accounts / real Hive / production live-memory capture service',
        'runtimeCutover': false,
        'durableIdentityConfigured': false,
        'clockPolicy': {
          'kind': 'actualDartDateTimeNow',
          'injectedClock': false,
          'exactBoundaryProof': false,
        },
        'cases': cases,
      }));
    } finally {
      await storage.close();
    }
  });

  test('actual empty anonymous jar has no stored login owners', () async {
    await AnonymousAccount().cookieJar.deleteAll();
    await record('anonymous-empty-jar');
  });

  test('real Box and owner orders differ and replacement changes owner order', () async {
    await Accounts.installCredentials(envelopeFixtureAccount('2'));
    await Accounts.installCredentials(envelopeFixtureAccount('10'));
    await record('stored-10-2-owner-2-10');
    await Accounts.installCredentials(envelopeFixtureAccount('2'));
    await record('same-key-replacement-owner-10-2');
  });

  test('real distinct raw 02 and 2 owners are not merged by numeric MID', () async {
    await Accounts.installCredentials(envelopeFixtureAccount('02'));
    await Accounts.installCredentials(envelopeFixtureAccount('2'));
    await record('distinct-raw-02-and-2-equal-mid');
  });

  test('actual legacy login policy preserves zero and negative MID', () async {
    final zero = envelopeFixtureAccount('0');
    await Accounts.installCredentials(zero);
    await Accounts.installCredentials(envelopeFixtureAccount('-2'));
    Accounts.selectTemporarily(AccountType.heartbeat, zero);
    await record('zero-and-negative-login-mid');
  });

  test('actual four slots temporary selection and history are captured', () async {
    for (final purpose in AccountType.values) {
      await Accounts.installCredentials(envelopeFixtureAccount(
        '${94000 + purpose.index}', purposes: {purpose},
      ));
    }
    await Accounts.refresh();
    await record('four-effective-purposes');
    Accounts.selectTemporarily(AccountType.heartbeat, AnonymousAccount());
    await record('temporary-heartbeat-anonymous-history-main');
  });

  test('actual anonymous nonempty persisted purposes survive capture', () async {
    AnonymousAccount().type.addAll(const {AccountType.video, AccountType.main});
    await record('anonymous-persisted-purposes');
  });

  test('full actual jar attributes UTF16 maps empty buckets and null credentials', () async {
    final account = envelopeFixtureAccount(
      '94030', accessKey: null, refreshToken: null,
    );
    addEnvelopeFixtureAttributes(account.cookieJar);
    await Accounts.installCredentials(account);
    await record('raw-utf16-full-attributes-nullable-credentials');
  });
}
