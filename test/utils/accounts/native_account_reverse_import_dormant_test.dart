import 'package:PiliPlus/services/native_accounts/native_account_reverse_import.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _jar() => {
  'schemaVersion': 2,
  'ignoreExpires': false,
  'provenance': {
    'capture': 'live', 'priorPersistence': 'unknown',
    'legacyHiveAttributesIncomplete': true, 'currentBucketOrderComplete': true,
  },
  'domainBuckets': <Object?>[], 'hostBuckets': <Object?>[],
};
Map<String, Object?> _envelope({bool login = false}) => {
  'schemaVersion': 2, 'scope': 'coherentLiveMemoryShadow', 'identityScope': 'captureLocal',
  'revision': 0, 'durableIdentityConfigured': false, 'durabilityVerified': false,
  'authoritySwitchAllowed': false, 'nativeWritesAllowed': false,
  'records': [
    {
      'record': 0, 'generation': 1, 'storageKeyUnits': null, 'mid': 0,
      'isLogin': false, 'accessKeyUnits': null, 'refreshTokenUnits': null,
      'persistedPurposes': ['video', 'main'], 'activated': false, 'jar': _jar(),
    },
    if (login) {
      'record': 1, 'generation': 2, 'storageKeyUnits': '777'.codeUnits, 'mid': 777,
      'isLogin': true, 'accessKeyUnits': null, 'refreshTokenUnits': null,
      'persistedPurposes': <String>[], 'activated': false, 'jar': _jar(),
    },
  ],
  'storedOrder': [if (login) {'keyUnits': '777'.codeUnits, 'record': 1}],
  'ownerOrder': [if (login) {'keyUnits': '777'.codeUnits, 'record': 1}],
  'selectionPurposes': ['main', 'heartbeat', 'recommend', 'video'],
  'selections': [0, 0, 0, 0], 'history': 0,
};

/// Independent test isolate: no Hive, Pref, Request, or anonymous factory.
void main() {
  for (final login in [false, true]) {
    test('dormant pure decode login=$login requires no live lifecycle', () {
      expect(() => GStorage.localCache, throwsA(isA<Error>()));
      final revision = Accounts.requestRevision;
      final decoded = NativeAccountReverseImport.decode(_envelope(login: login));
      expect(decoded.accountKeys, login ? ['777'] : isEmpty);
      expect(Accounts.requestRevision, revision);
      expect(() => Accounts.account, throwsA(isA<Error>()));
      expect(() => GStorage.localCache, throwsA(isA<Error>()));
      expect(() => GStorage.setting, throwsA(isA<Error>()));
    });
  }
}
