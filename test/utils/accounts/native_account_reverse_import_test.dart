import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/account_install_persistence_port.dart';
import 'package:PiliPlus/services/native_accounts/account_reset_persistence_port.dart';
import 'package:PiliPlus/services/native_accounts/native_account_reverse_import.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'account_test_storage.dart';
import 'native_account_envelope_fixtures.dart';

Map<String, Object?> _copy(Map<String, Object?> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();
List<Map<String, Object?>> _records(Map<String, Object?> value) =>
    (value['records']! as List).map((record) => (record as Map).cast<String, Object?>()).toList();
Map<String, Object?> _normalized(Map<String, Object?> value) {
  final copy = _copy(value)..remove('revision');
  for (final record in _records(copy)) {
    record.remove('generation');
  }
  return copy;
}

/// Deterministic empty-target fixture: delete/reset only, with no clear()'s
/// fire-and-forget buvid activation. All actual Hive/jar deletes are awaited.
Future<void> _prepareEmptyTarget() async {
  final anonymous = AnonymousAccount();
  for (final purpose in AccountType.values) {
    Accounts.selectTemporarily(purpose, anonymous);
  }
  for (final account in Accounts.account.values.toList()) {
    await account.delete();
  }
  await anonymous.delete();
  AnonymousAccount().activated = true;
}

void main() {
  late AccountTestStorage storage;
  setUpAll(() async { storage = await AccountTestStorage.open(); });
  setUp(() async {
    await _prepareEmptyTarget();
    AnonymousAccount().type.clear();
  });
  tearDownAll(() => storage.close());

  test('full candidate restores anonymous and login attrs, owner order, slots and fresh stamps', () async {
    final first = envelopeFixtureAccount('2', purposes: {AccountType.main, AccountType.video});
    addEnvelopeFixtureAttributes(first.cookieJar);
    final second = envelopeFixtureAccount('10', purposes: {AccountType.main});
    final anonymous = AnonymousAccount()
      ..type.addAll([AccountType.video, AccountType.main]);
    addEnvelopeFixtureAttributes(anonymous.cookieJar);
    await Accounts.installCredentials(first);
    await Accounts.installCredentials(second);
    await Accounts.refresh();
    Accounts.selectTemporarily(AccountType.heartbeat, first);
    anonymous.activated = false;
    final oldStamp = Accounts.captureRequest(first)!;
    final oldAnonymous = Accounts.captureRequest(anonymous)!;
    final capture = Accounts.captureLiveMemoryShadow().value;
    final decoded = NativeAccountReverseImport.decode(capture);
    expect(decoded.accountKeys, ['10', '2']);
    await _prepareEmptyTarget();
    anonymous.type.clear();
    await const NativeAccountReverseImportService().apply(decoded);
    expect(_normalized(Accounts.captureLiveMemoryShadow().value), _normalized(capture));
    expect(Accounts.isCurrentRequest(oldStamp), false);
    expect(Accounts.isCurrentRequest(oldAnonymous), false);
    expect(Accounts.captureRequest(Accounts.account.get('2')!), isNotNull);
    // Correct owner order preserves last-owner priority on a later refresh.
    await Accounts.refresh();
    expect(identical(Accounts.main, Accounts.account.get('10')), true);
  });

  test('empty jar and missing DedeUserID preserve explicit cached key and MID', () async {
    for (final empty in [false, true]) {
      final account = envelopeFixtureAccount('02');
      await Accounts.installCredentials(account);
      expect(account.storageKey, '02');
      expect(account.mid, 2);
      if (empty) {
        await account.cookieJar.deleteAll();
      } else {
        account.cookieJar.domainCookies['bilibili.com']!['/']!.remove('DedeUserID');
      }
      final capture = Accounts.captureLiveMemoryShadow().value;
      final decoded = NativeAccountReverseImport.decode(capture);
      await _prepareEmptyTarget();
      await const NativeAccountReverseImportService().apply(decoded);
      final restored = Accounts.account.get('02')!;
      expect(restored.storageKey, '02');
      expect(restored.mid, 2);
      expect(_normalized(Accounts.captureLiveMemoryShadow().value), _normalized(capture));
      await _prepareEmptyTarget();
    }
  });

  test('raw equal-MID owners and mutated identity Cookie remain distinct', () async {
    final first = envelopeFixtureAccount('02');
    final second = envelopeFixtureAccount('2');
    await Accounts.installCredentials(first);
    await Accounts.installCredentials(second);
    expect(first.mid, 2);
    expect(second.mid, 2);
    first.cookieJar.domainCookies['bilibili.com']!['/']!['DedeUserID']!.cookie.value = '999';
    final capture = Accounts.captureLiveMemoryShadow().value;
    final decoded = NativeAccountReverseImport.decode(capture);
    await _prepareEmptyTarget();
    await const NativeAccountReverseImportService().apply(decoded);
    expect(Accounts.account.keys.toList(), ['02', '2']);
    expect(Accounts.account.get('02')!.mid, 2);
    expect(Accounts.account.get('2')!.mid, 2);
    expect(_normalized(Accounts.captureLiveMemoryShadow().value), _normalized(capture));
  });

  test('restore false-activated records and temporary anonymous selection without network', () async {
    final account = envelopeFixtureAccount('11', purposes: {AccountType.main})..activated = false;
    await Accounts.installCredentials(account);
    Accounts.selectTemporarily(AccountType.main, AnonymousAccount());
    final capture = Accounts.captureLiveMemoryShadow().value;
    final decoded = NativeAccountReverseImport.decode(capture);
    await _prepareEmptyTarget();
    final prior = Request.dio.httpClientAdapter;
    final counter = _CountingAdapter();
    Request.dio.httpClientAdapter = counter;
    try {
      await const NativeAccountReverseImportService().apply(decoded);
      expect(counter.requests, 0);
      expect(Accounts.account.get('11')!.activated, false);
      expect(Accounts.main, isA<AnonymousAccount>());
      expect(_normalized(Accounts.captureLiveMemoryShadow().value), _normalized(capture));
    } finally {
      Request.dio.httpClientAdapter = prior;
    }
  });

  test('nonempty target rejected without merge, delete or old ownership mutation', () async {
    final empty = NativeAccountReverseImport.decode(Accounts.captureLiveMemoryShadow().value);
    final account = envelopeFixtureAccount('777', purposes: {AccountType.main});
    await Accounts.installCredentials(account);
    final stamp = Accounts.captureRequest(account)!;
    final revision = Accounts.requestRevision;
    await expectLater(const NativeAccountReverseImportService().apply(empty), throwsStateError);
    expect(identical(Accounts.account.get('777'), account), true);
    expect(Accounts.isCurrentRequest(stamp), true);
    expect(Accounts.requestRevision, revision);
  });

  test('anonymous reset in progress rejected before write', () async {
    final decoded = NativeAccountReverseImport.decode(Accounts.captureLiveMemoryShadow().value);
    final reset = AnonymousAccount().delete();
    await expectLater(const NativeAccountReverseImportService().apply(decoded), throwsStateError);
    await reset;
    expect(Accounts.account.isEmpty, true);
  });

  test('decode owns immutable raw blueprint and no caller edits leak', () {
    final source = _copy(Accounts.captureLiveMemoryShadow().value);
    final decoded = NativeAccountReverseImport.decode(source);
    _records(source).first['activated'] = false;
    expect(_records(decoded.value).first['activated'], true);
    expect(() => decoded.value['revision'] = 99, throwsUnsupportedError);
    expect(() => (decoded.value['records']! as List).clear(), throwsUnsupportedError);
    expect(() => (decoded.value['records']! as List).first['activated'] = false, throwsUnsupportedError);
  });

  test('actual Hive write then error preserves rows but no live owners or automatic replay', () async {
    final account = envelopeFixtureAccount('777');
    await Accounts.installCredentials(account);
    final decoded = NativeAccountReverseImport.decode(Accounts.captureLiveMemoryShadow().value);
    await Accounts.clear();
    final oldAnonymous = Accounts.captureRequest(AnonymousAccount())!;
    final port = _WriteThenErrorPort();
    final service = NativeAccountReverseImportService(persistencePort: port);
    await expectLater(service.apply(decoded), throwsA(isA<HiveError>()));
    final written = Accounts.account.get('777')!;
    expect(port.writes, 1);
    expect(Accounts.account.keys.toList(), ['777']);
    expect(Accounts.captureRequest(written), isNull);
    expect(Accounts.captureRequest(AnonymousAccount()), isNull);
    expect(Accounts.isCurrentRequest(oldAnonymous), false);
    expect(Accounts.refresh, throwsStateError);
    await expectLater(Accounts.installCredentials(envelopeFixtureAccount('888')), throwsStateError);
    await expectLater(service.apply(decoded), throwsStateError);
    expect(port.writes, 1);
    expect(identical(Accounts.account.get('777'), written), true);
    await Accounts.clear();
    expect(Accounts.account.isEmpty, true);
    expect(Accounts.captureRequest(AnonymousAccount()), isNotNull);
  });

  test('failed real clear acknowledgement cannot unlock a failed restore', () async {
    final account = envelopeFixtureAccount('777');
    await Accounts.installCredentials(account);
    final decoded = NativeAccountReverseImport.decode(Accounts.captureLiveMemoryShadow().value);
    await Accounts.clear();
    await expectLater(
      NativeAccountReverseImportService(persistencePort: _WriteThenErrorPort()).apply(decoded),
      throwsA(isA<HiveError>()),
    );
    final port = _ClearThenErrorPort();
    await expectLater(Accounts.clear(persistencePort: port), throwsA(isA<HiveError>()));
    expect(port.clears, 1);
    expect(Accounts.account.isEmpty, true);
    expect(Accounts.captureRequest(AnonymousAccount()), isNull);
    expect(Accounts.refresh, throwsStateError);
    await expectLater(const NativeAccountReverseImportService().apply(decoded), throwsStateError);
    final recoveryPort = _BlockedClearPort();
    final recovery = Accounts.clear(persistencePort: recoveryPort);
    await recoveryPort.started.future;
    await expectLater(Accounts.clear(), throwsStateError);
    await expectLater(AnonymousAccount().delete(), throwsStateError);
    await expectLater(const NativeAccountReverseImportService().apply(decoded), throwsStateError);
    expect(Accounts.captureRequest(AnonymousAccount()), isNull);
    recoveryPort.release.complete();
    await recovery;
    expect(Accounts.captureRequest(AnonymousAccount()), isNotNull);
    await const NativeAccountReverseImportService().apply(decoded);
    expect(Accounts.captureRequest(Accounts.account.get('777')!), isNotNull);
  });

  test('malformed shape, types, nullable fields, purposes, owner order and history fail before touching live', () async {
    final account = envelopeFixtureAccount('777');
    addEnvelopeFixtureAttributes(account.cookieJar);
    await Accounts.installCredentials(account);
    final capture = Accounts.captureLiveMemoryShadow().value;
    final mutations = <void Function(Map<String, Object?>)>[
      (value) => value['schemaVersion'] = 2.0,
      (value) => value['unknown'] = null,
      (value) => value['revision'] = -1,
      (value) => value['nativeWritesAllowed'] = true,
      (value) => value['selectionPurposes'] = ['heartbeat', 'main', 'recommend', 'video'],
      (value) => value['selections'] = [0, 0, 0],
      (value) => value['history'] = 1,
      (value) => value['ownerOrder'] = [],
      (value) => value['storedOrder'] = [],
      (value) => _records(value)[1]['mid'] = null,
      (value) => _records(value)[1]['record'] = 1.0,
      (value) => _records(value)[1]['generation'] = _records(value)[0]['generation'],
      (value) => _records(value)[1]['activated'] = 'true',
      (value) => _records(value)[1].remove('refreshTokenUnits'),
      (value) => _records(value)[1]['persistedPurposes'] = ['main', 'main'],
      (value) => _records(value)[1]['storageKeyUnits'] = [65536],
      (value) {
        (_records(value)[1]['jar']! as Map).remove('provenance');
      },
      (value) {
        final jar = _records(value)[1]['jar']! as Map;
        final cookie = ((jar['domainBuckets'] as List).first['paths'] as List).first['cookies'][0] as Map;
        cookie['secure'] = 'true';
      },
      (value) {
        final jar = _records(value)[1]['jar']! as Map;
        (((jar['domainBuckets'] as List).first['paths'] as List).first['cookies'][0] as Map)
            .remove('cookieDomainUnits');
      },
    ];
    final revision = Accounts.requestRevision;
    for (final mutate in mutations) {
      final value = _copy(capture);
      mutate(value);
      expect(() => NativeAccountReverseImport.decode(value),
        throwsA(isA<NativeAccountReverseImportException>()));
    }
    expect(Accounts.requestRevision, revision);
    expect(identical(Accounts.account.get('777'), account), true);
  });

  test('complete candidate cumulative units reject locally legal Cookie values', () async {
    final account = envelopeFixtureAccount('777');
    await Accounts.installCredentials(account);
    final value = _copy(Accounts.captureLiveMemoryShadow().value);
    final jar = _records(value)[1]['jar']! as Map;
    final cookies = ((jar['domainBuckets'] as List).first['paths'] as List).first['cookies'] as List;
    final template = (jsonDecode(jsonEncode(cookies.first)) as Map).cast<String, Object?>();
    cookies.clear();
    for (var index = 0; index < 33; index++) {
      cookies.add(Map<String, Object?>.of(template)
        ..['keyUnits'] = 'c$index'.codeUnits
        ..['valueUnits'] = List<int>.filled(65536, 65));
    }
    expect(() => NativeAccountReverseImport.decode(value),
      throwsA(isA<NativeAccountReverseImportException>().having((error) => error.code, 'code', 'resourceLimit')));
    expect(identical(Accounts.account.get('777'), account), true);
  });
}

final class _CountingAdapter implements HttpClientAdapter {
  int requests = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    requests++;
    return ResponseBody.fromString('{}', 200);
  }
  @override
  void close({bool force = false}) {}
}

/// The injected error is AFTER an actual production Hive write. No fake Box,
/// rollback, reread rewrite, or global composition replacement is involved.
final class _WriteThenErrorPort implements AccountInstallPersistencePort {
  int writes = 0;
  @override
  Future<void> writeLegacyImport(Box<LoginAccount> box, Map<String, LoginAccount> values) async {
    writes++;
    await box.putAll(values);
    throw HiveError('synthetic lost acknowledgement after real write');
  }
  @override
  Future<void> writeLegacyInstall(Box<LoginAccount> box, String key, LoginAccount value) =>
      box.put(key, value);
}

final class _ClearThenErrorPort implements AccountResetPersistencePort {
  int clears = 0;
  @override
  Future<int> clearLegacyAccounts(Box<LoginAccount> box) async {
    clears++;
    await box.clear();
    throw HiveError('synthetic lost acknowledgement after real clear');
  }
  @override
  Future<void> clearAnonymousCookies(AnonymousAccount owner) => owner.cookieJar.deleteAll();
}

final class _BlockedClearPort implements AccountResetPersistencePort {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<int> clearLegacyAccounts(Box<LoginAccount> box) async {
    started.complete();
    await release.future;
    return box.clear();
  }
  @override
  Future<void> clearAnonymousCookies(AnonymousAccount owner) => owner.cookieJar.deleteAll();
}
