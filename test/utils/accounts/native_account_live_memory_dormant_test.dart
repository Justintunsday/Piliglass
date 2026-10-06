import 'dart:io';

import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// Separate isolate with real Hive but no Pref boxes or anonymous lifecycle.
/// Constructing the anonymous factory here would initialize credentials and
/// attempt to read the still-uninitialized localCache for gRPC metadata.
void main() {
  test('dormant capture reads existing registry without constructing anonymous', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final directory = await Directory.systemTemp.createTemp('piliplus-dormant-capture-');
    Hive.init(directory.path);
    GStorage.regAdapter();
    await Accounts.init();
    try {
      expect(() => GStorage.localCache, throwsA(isA<Error>()));
      final revision = Accounts.requestRevision;
      expect(Accounts.captureLiveMemoryShadow,
        throwsA(isA<AccountLiveMemoryShadowException>().having(
          (e) => e.code, 'code', 'unavailable')));
      expect(Accounts.requestRevision, revision);
      expect(Accounts.account.isEmpty, true);
      // Capture did not initialize storage or require the anonymous factory.
      expect(() => GStorage.localCache, throwsA(isA<Error>()));
    } finally {
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });
}
