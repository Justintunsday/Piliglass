import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'account_test_storage.dart';

LoginAccount _account(int mid, String session) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'synthetic-install-port-csrf',
    'SESSDATA': session,
  }),
  'synthetic-install-port-access',
  'synthetic-install-port-refresh',
)..activated = true;

void main() {
  late AccountTestStorage storage;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });
  setUp(() => storage.reset());
  tearDownAll(() => storage.close());

  test('install exposes real Hive candidate before await but not its generation', () async {
    final old = _account(820001, 'synthetic-old');
    await Accounts.installCredentials(old);
    final oldStamp = Accounts.captureRequest(old)!;
    final candidate = _account(820001, 'synthetic-new');

    final installing = Accounts.installCredentials(candidate);
    expect(Accounts.account.get(candidate.storageKey), same(candidate));
    expect(Accounts.isCurrentRequest(oldStamp), isFalse);
    expect(Accounts.captureRequest(candidate), isNull);

    await installing;
    final newStamp = Accounts.captureRequest(candidate)!;
    expect(newStamp.generation, greaterThan(oldStamp.generation));
    expect(Accounts.isCurrentRequest(newStamp), isTrue);
    expect(Accounts.isCurrentRequest(oldStamp), isFalse);
  });

  test('bulk import exposes every pending candidate before any generation', () async {
    final firstOld = _account(820003, 'synthetic-first-old');
    final secondOld = _account(820002, 'synthetic-second-old');
    await Accounts.installCredentials(firstOld);
    await Accounts.installCredentials(secondOld);
    final firstStamp = Accounts.captureRequest(firstOld)!;
    final secondStamp = Accounts.captureRequest(secondOld)!;
    final first = _account(820003, 'synthetic-first-new');
    final second = _account(820002, 'synthetic-second-new');

    final importing = Accounts.importCredentials({
      first.storageKey: first,
      second.storageKey: second,
    });
    expect(Accounts.account.get(first.storageKey), same(first));
    expect(Accounts.account.get(second.storageKey), same(second));
    expect(Accounts.isCurrentRequest(firstStamp), isFalse);
    expect(Accounts.isCurrentRequest(secondStamp), isFalse);
    expect(Accounts.captureRequest(first), isNull);
    expect(Accounts.captureRequest(second), isNull);

    await importing;
    final newFirstStamp = Accounts.captureRequest(first)!;
    final newSecondStamp = Accounts.captureRequest(second)!;
    expect(newFirstStamp.generation, greaterThan(firstStamp.generation));
    expect(newSecondStamp.generation, greaterThan(secondStamp.generation));
    expect(Accounts.isCurrentRequest(newFirstStamp), isTrue);
    expect(Accounts.isCurrentRequest(newSecondStamp), isTrue);
  });

  test('real install encoding failure cannot revive the rolled-back old owner', () async {
    final old = _account(820004, 'synthetic-old');
    await Accounts.installCredentials(old);
    final oldStamp = Accounts.captureRequest(old)!;
    final candidate = _account(820004, 'synthetic-failed');
    final failure = StateError('synthetic install encoding failure');
    final probe = _EncodingProbeState(candidate.mid, failure);
    Hive.registerAdapter<LoginAccount>(_EncodingProbeAdapter(probe), override: true);
    try {
      final installing = Accounts.installCredentials(candidate);
      expect(Accounts.isCurrentRequest(oldStamp), isFalse);
      expect(Accounts.captureRequest(candidate), isNull);
      await expectLater(installing, throwsA(same(failure)));
      expect(probe.writtenMIDs, [candidate.mid]);
      // Actual Hive rollback restores this object, but not its request identity.
      expect(Accounts.account.get(old.storageKey), same(old));
      expect(Accounts.captureRequest(candidate), isNull);
      expect(Accounts.captureRequest(old), isNull);
      await Accounts.refresh();
      expect(Accounts.captureRequest(old), isNull);
      expect(Accounts.captureRequest(candidate), isNull);
      expect(Accounts.isCurrentRequest(oldStamp), isFalse);
    } finally {
      Hive.registerAdapter<LoginAccount>(LoginAccountAdapter(), override: true);
    }
  });

  test('second bulk encoding failure rolls back the real transaction in input order', () async {
    final firstOld = _account(820006, 'synthetic-first-old');
    final secondOld = _account(820005, 'synthetic-second-old');
    await Accounts.installCredentials(firstOld);
    await Accounts.installCredentials(secondOld);
    final firstStamp = Accounts.captureRequest(firstOld)!;
    final secondStamp = Accounts.captureRequest(secondOld)!;
    final first = _account(820006, 'synthetic-first-failed');
    final second = _account(820005, 'synthetic-second-failed');
    final failure = StateError('synthetic second import encoding failure');
    final probe = _EncodingProbeState(second.mid, failure);
    Hive.registerAdapter<LoginAccount>(_EncodingProbeAdapter(probe), override: true);
    try {
      final importing = Accounts.importCredentials({
        first.storageKey: first,
        second.storageKey: second,
      });
      expect(Accounts.isCurrentRequest(firstStamp), isFalse);
      expect(Accounts.isCurrentRequest(secondStamp), isFalse);
      expect(Accounts.captureRequest(first), isNull);
      expect(Accounts.captureRequest(second), isNull);
      await expectLater(importing, throwsA(same(failure)));
      expect(probe.writtenMIDs, [first.mid, second.mid]);
      // A per-entry import would have committed first before failing second.
      expect(Accounts.account.get(firstOld.storageKey), same(firstOld));
      expect(Accounts.account.get(secondOld.storageKey), same(secondOld));
      for (final value in [firstOld, secondOld, first, second]) {
        expect(Accounts.captureRequest(value), isNull);
      }
      await Accounts.refresh();
      for (final value in [firstOld, secondOld, first, second]) {
        expect(Accounts.captureRequest(value), isNull);
      }
      expect(Accounts.isCurrentRequest(firstStamp), isFalse);
      expect(Accounts.isCurrentRequest(secondStamp), isFalse);
    } finally {
      Hive.registerAdapter<LoginAccount>(LoginAccountAdapter(), override: true);
    }
  });
}

class _EncodingProbeState {
  final int failingMID;
  final StateError failure;
  final List<int> writtenMIDs = [];

  _EncodingProbeState(this.failingMID, this.failure);
}

/// The actual type9 encoder runs before the synthetic encoding failure.
/// This proves rollback/error forwarding, not a post-disk acknowledgment.
class _EncodingProbeAdapter extends LoginAccountAdapter {
  final _EncodingProbeState probe;

  _EncodingProbeAdapter(this.probe);

  @override
  void write(BinaryWriter writer, LoginAccount obj) {
    probe.writtenMIDs.add(obj.mid);
    super.write(writer, obj);
    if (obj.mid == probe.failingMID) throw probe.failure;
  }
}
