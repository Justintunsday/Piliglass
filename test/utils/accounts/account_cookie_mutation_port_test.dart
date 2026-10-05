import 'dart:io';

import 'package:PiliPlus/services/native_accounts/account_cookie_mutation_port.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'account_test_storage.dart';

LoginAccount _account(int mid, String session) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'synthetic-port-csrf',
    'SESSDATA': session,
  }),
  'synthetic-port-access',
  'synthetic-port-refresh',
);

void main() {
  late AccountTestStorage storage;
  const port = DartAccountCookieMutationPort();
  final uri = Uri.parse('https://api.bilibili.com/x/port');

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });
  setUp(() => storage.reset());
  tearDownAll(() => storage.close());

  test('real jar mutates before await and caller retains revision notification', () async {
    final owner = _account(810001, 'synthetic-first');
    await Accounts.installCredentials(owner);
    final stamp = Accounts.captureRequest(owner)!;
    final revision = Accounts.requestRevision;
    final saving = port.saveResponseCookies(owner, uri, [
      Cookie('port_response', 'immediate')
        ..domain = '.bilibili.com'
        ..path = '/x'
        ..secure = true
        ..httpOnly = true,
    ]);
    final saved = owner.cookieJar.domainCookies['bilibili.com']!['/x']!['port_response']!;
    expect(saved.cookie.value, 'immediate');
    expect(saved.cookie.secure, isTrue);
    expect(saved.cookie.httpOnly, isTrue);
    expect(Accounts.requestRevision, revision);
    Accounts.notifyCookieMutation(owner);
    expect(Accounts.requestRevision, greaterThan(revision));
    expect(Accounts.isCurrentRequest(stamp), isTrue);
    await saving;
    await owner.onChange();
    expect(Accounts.account.get(owner.storageKey), same(owner));
  });

  test('uninstalled and anonymous legacy persistence remain nullable', () {
    final candidate = _account(810002, 'synthetic-uninstalled');
    expect(candidate.onChange(), isNull);
    expect(port.persistLegacyAccount(candidate), isNull);
    expect(AnonymousAccount().onChange(), isNull);
    expect(
      () => port.saveResponseCookies(candidate, uri, [Cookie('unavailable', 'blocked')]),
      throwsStateError,
    );
    expect(candidate.cookieJar.hostCookies, isEmpty);
    expect(Accounts.account.containsKey(candidate.storageKey), isFalse);
  });

  test('same-MID predecessor cannot mutate or persist its successor', () async {
    final old = _account(810003, 'synthetic-old');
    await Accounts.installCredentials(old);
    final stamp = Accounts.captureRequest(old)!;
    final successor = _account(810003, 'synthetic-new');
    await Accounts.installCredentials(successor);
    expect(Accounts.isCurrentRequest(stamp), isFalse);
    expect(old.onChange(), isNull);
    expect(port.persistLegacyAccount(old), isNull);
    expect(
      () => port.saveResponseCookies(old, uri, [Cookie('stale', 'blocked')]),
      throwsStateError,
    );
    expect(successor.cookieJar.hostCookies, isEmpty);
    expect(successor.cookieJar.toJson()['SESSDATA'], 'synthetic-new');
    await old.delete();
    expect(old.onChange(), isNull);
    expect(Accounts.account.get(successor.storageKey), same(successor));
    final persisting = successor.onChange();
    expect(persisting, isNotNull);
    await persisting;
    expect(Accounts.ownsCredentials(successor), isTrue);
  });

  test('real Hive encoding failure propagates once after real Cookie mutation', () async {
    final owner = _account(810004, 'synthetic-fault');
    await Accounts.installCredentials(owner);
    final stamp = Accounts.captureRequest(owner)!;
    final adapter = _EncodingProbeAdapter();
    Hive.registerAdapter<LoginAccount>(adapter, override: true);
    try {
      final persisting = port.persistLegacyAccount(owner);
      expect(persisting, isNotNull);
      await persisting;
      expect(adapter.writes, 1);

      await port.saveResponseCookies(owner, uri, [
        Cookie('before_failure', 'memory-applied')..setBiliDomain(),
      ]);
      Accounts.notifyCookieMutation(owner);
      final failure = StateError('synthetic Hive encoding failure');
      adapter.failure = failure;
      final failedPersistence = owner.onChange();
      expect(failedPersistence, isNotNull);
      await expectLater(failedPersistence!, throwsA(same(failure)));
      expect(adapter.writes, 2);
      expect(owner.cookieJar.toJson()['before_failure'], 'memory-applied');
      expect(Accounts.account.get(owner.storageKey), same(owner));
      expect(Accounts.isCurrentRequest(stamp), isTrue);
    } finally {
      Hive.registerAdapter<LoginAccount>(LoginAccountAdapter(), override: true);
    }
  });
}

/// Real Hive calls the production type9 encoder before this synthetic failure.
/// This tests error forwarding, not a post-disk acknowledgment or durable receipt.
class _EncodingProbeAdapter extends LoginAccountAdapter {
  int writes = 0;
  StateError? failure;

  @override
  void write(BinaryWriter writer, LoginAccount obj) {
    writes++;
    super.write(writer, obj);
    final error = failure;
    if (error != null) throw error;
  }
}
