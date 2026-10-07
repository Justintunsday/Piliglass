import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/native_account_live_memory_capture.dart';
import 'package:PiliPlus/services/native_accounts/native_ordered_cookie_jar_export.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';
import 'native_account_envelope_fixtures.dart';

/// Independent file isolate: Accounts.account is static late final. The live
/// producer's original objects/stamps cannot be reused as cold authorization.
void main() {
  test('real type8/type9 write close reopen captures cold order and attribute loss', () async {
    final originals = [
      envelopeFixtureAccount('2', purposes: {AccountType.video}),
      envelopeFixtureAccount('10', purposes: {AccountType.main}),
    ];
    addEnvelopeFixtureAttributes(originals.first.cookieJar);
    // Actual pre-Hive jars are diagnostic observations, not a reconstructed
    // pre-Hive account envelope or fabricated credential generations.
    final before = [
      for (final account in originals) {
        'rawStorageKeyUnits': account.storageKey.codeUnits,
        'activated': account.activated,
        'jar': NativeOrderedCookieJarExporter.export(account.cookieJar),
      },
    ];
    // This existing helper writes keys by numeric MID. 2/10 deliberately have
    // the same raw keys; raw 02/2 continuity is outside this cold fixture.
    final storage = await AccountTestStorage.open(initialAccounts: originals);
    try {
      final restored = Accounts.account.values.toList();
      expect(restored.map((account) => account.storageKey), ['10', '2']);
      expect(restored.every((account) => !account.activated), true);
      for (final original in originals) {
        expect(Accounts.captureRequest(original), isNull);
      }
      final revision = Accounts.requestRevision;
      expect(Accounts.captureLiveMemoryShadow,
        throwsA(isA<AccountLiveMemoryShadowException>().having(
          (error) => error.code, 'code', 'unavailable',
        )));
      expect(Accounts.requestRevision, revision);
      // Normal anonymous lifecycle, outside the capture algorithm, supplies
      // its fresh generation. Do not refresh restored owners before recording:
      // their false activated state and all-anonymous effective slots matter.
      AnonymousAccount().activated = true;
      Accounts.captureRequest(AnonymousAccount());
      final started = DateTime.now().microsecondsSinceEpoch;
      final envelope = await NativeAccountLiveMemoryCaptureService().capture();
      final finished = DateTime.now().microsecondsSinceEpoch;
      expect(restored.every((account) => !account.activated), true);
      expect(envelope['nativeWritesAllowed'], false);
      expect(envelope['authoritySwitchAllowed'], false);
      expect(envelope['durabilityVerified'], false);
      final file = File('build/native-account-envelope-check/hive-reopened.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'schemaVersion': 1,
        'source': 'actual Hive type8/type9 write-close-reopen / production capture service',
        'runtimeCutover': false,
        'durableIdentityConfigured': false,
        'crossRestartStampContinuity': false,
        'preHiveJarObservations': before,
        'clockPolicy': {
          'kind': 'actualDartDateTimeNow',
          'injectedClock': false,
          'exactBoundaryProof': false,
        },
        'cases': [{
          'id': 'actual-hive-reopen-before-refresh',
          'captureStartedMicroseconds': started,
          'captureFinishedMicroseconds': finished,
          'envelope': envelope,
        }],
      }));
    } finally {
      await storage.close();
    }
  });
}
