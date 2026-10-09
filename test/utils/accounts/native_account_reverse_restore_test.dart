import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/native_account_reverse_import.dart';
import 'package:PiliPlus/services/native_accounts/native_account_reverse_restore_store.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'account_test_storage.dart';
import 'native_account_envelope_fixtures.dart';

const _boxName = 'account_reverse_restore';
const _epoch = 'synthetic-authority-epoch';
const _firstID = '11111111-1111-4111-8111-111111111111';
const _secondID = '22222222-2222-4222-8222-222222222222';
const _thirdID = '33333333-3333-4333-8333-333333333333';
const _manifestKey = NativeAccountReverseRestoreStore.manifestKey;

String _recordKey(String transactionID) =>
    '${NativeAccountReverseRestoreStore.recordKeyPrefix}$transactionID';

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

Map<String, Object?> _copy(Map<String, Object?> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();

enum _Fault {
  writeBefore,
  recordWriteThenError,
  recordReadbackError,
  manifestWriteThenError,
  readAfterPublish,
}

final class _FaultVault implements NativeAccountReverseRestoreVault {
  final values = <String, String>{};
  final paused = Completer<void>();
  int removeCalls = 0;
  _Fault? fault;
  String? injectManifestOnRecordWrite;
  bool _pauseWrite = false;
  bool _pauseRead = false;
  bool _pauseManifestWrite = false;
  bool _manifestWritten = false;
  int _recordWrites = 0;
  Completer<void>? _suspended;

  int get candidateCount => values.keys
      .where((key) => key.startsWith(NativeAccountReverseRestoreStore.recordKeyPrefix))
      .length;

  @override
  Object get coordinationDomain => this;

  void arm(_Fault next) {
    fault = next;
    _manifestWritten = false;
    _recordWrites = 0;
  }

  void pauseNextWrite() => _pauseWrite = true;
  void pauseNextRead() => _pauseRead = true;
  void pauseNextManifestWrite() => _pauseManifestWrite = true;
  bool get isPaused => _suspended != null;

  void release() {
    _suspended?.complete();
    _suspended = null;
  }

  Future<void> _suspend() async {
    final suspended = Completer<void>();
    _suspended = suspended;
    if (!paused.isCompleted) paused.complete();
    await suspended.future;
  }

  @override
  Future<String?> read(String key) async {
    if (_pauseRead) {
      _pauseRead = false;
      await _suspend();
    }
    if (key == _manifestKey && _manifestWritten && fault == _Fault.readAfterPublish) {
      fault = null;
      throw StateError('synthetic lost manifest readback');
    }
    if (key != _manifestKey && _recordWrites > 0 && fault == _Fault.recordReadbackError) {
      fault = null;
      throw StateError('synthetic record readback error');
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (_pauseWrite) {
      _pauseWrite = false;
      await _suspend();
    }
    if (_pauseManifestWrite && key == _manifestKey) {
      _pauseManifestWrite = false;
      await _suspend();
    }
    if (fault == _Fault.writeBefore) {
      fault = null;
      throw StateError('synthetic write-before');
    }
    values[key] = value;
    if (key == _manifestKey) {
      _manifestWritten = true;
      if (fault == _Fault.manifestWriteThenError) {
        fault = null;
        throw StateError('synthetic manifest write-then-error');
      }
    } else {
      _recordWrites++;
      final injected = injectManifestOnRecordWrite;
      if (injected != null) {
        values[_manifestKey] = injected;
        injectManifestOnRecordWrite = null;
      }
      if (fault == _Fault.recordWriteThenError) {
        fault = null;
        throw StateError('synthetic record write-then-error');
      }
    }
  }

  @override
  Future<void> remove(String key) async {
    removeCalls++;
    values.remove(key);
  }
}

/// Delegates to a real Hive vault while allowing one controlled manifest-write
/// pause for two-wrapper interleaving tests.
final class _PausingVault implements NativeAccountReverseRestoreVault {
  _PausingVault(this.inner);

  final NativeAccountReverseRestoreVault inner;
  final paused = Completer<void>();
  bool _pauseManifest = false;
  Completer<void>? _suspended;

  @override
  Object get coordinationDomain => inner.coordinationDomain;

  void pauseManifestWrite() => _pauseManifest = true;

  void release() {
    _suspended?.complete();
    _suspended = null;
  }

  @override
  Future<String?> read(String key) => inner.read(key);

  @override
  Future<void> write(String key, String value) async {
    if (_pauseManifest && key == _manifestKey) {
      _pauseManifest = false;
      final suspended = Completer<void>();
      _suspended = suspended;
      if (!paused.isCompleted) paused.complete();
      await suspended.future;
    }
    await inner.write(key, value);
  }

  @override
  Future<void> remove(String key) => inner.remove(key);
}

NativeAccountReverseRestoreStore _faultStore(_FaultVault vault, {String? id}) =>
    NativeAccountReverseRestoreStore(
      vault: vault,
      transactionIDFactory: id == null ? null : () => id,
    );

void main() {
  late AccountTestStorage storage;
  setUpAll(() async { storage = await AccountTestStorage.open(); });
  setUp(() async {
    await storage.reset();
    AnonymousAccount().type.clear();
    final box = await Hive.openBox<String>(_boxName);
    await box.clear();
    await box.close();
  });
  tearDownAll(() => storage.close());

  Future<Map<String, Object?>> captureWith(String key) async {
    await Accounts.installCredentials(envelopeFixtureAccount(key));
    return _copy(Accounts.captureLiveMemoryShadow().value);
  }

  test('real Hive vault survives close and reopen and leaves legacy objects untouched', () async {
    final envelope = await captureWith('2');
    final legacyBefore = Accounts.account.toMap();
    final box = await Hive.openBox<String>(_boxName);
    final hiveStore = NativeAccountReverseRestoreStore(
      vault: HiveNativeAccountReverseRestoreVault(box),
      transactionIDFactory: () => _firstID,
    );
    final receipt = await hiveStore.importRestore(
      envelope: envelope,
      authorityEpoch: _epoch,
      createdAtMicroseconds: 100,
    );
    expect(receipt.transactionID, _firstID);
    expect(receipt.recoveredWriteAcknowledgment, false);
    final loaded = await hiveStore.loadRestore();
    expect(loaded, isNotNull);
    final loadedValue = loaded!;
    expect(loadedValue.envelope.value, envelope);
    expect(jsonEncode(loadedValue.envelope.value), jsonEncode(envelope));
    expect(loadedValue.authorityEpoch, _epoch);
    expect(loadedValue.createdAtMicroseconds, 100);
    final legacyAfter = Accounts.account.toMap();
    expect(legacyAfter.keys.toList(), legacyBefore.keys.toList());
    for (final key in legacyBefore.keys) {
      expect(identical(legacyAfter[key], legacyBefore[key]), true);
      expect(jsonEncode(legacyAfter[key]!.toJson()),
        jsonEncode(legacyBefore[key]!.toJson()));
    }
    await box.close();

    final reopened = await Hive.openBox<String>(_boxName);
    final restarted = NativeAccountReverseRestoreStore(
      vault: HiveNativeAccountReverseRestoreVault(reopened));
    final afterRestart = await restarted.loadRestore();
    expect(afterRestart, isNotNull);
    final restartedValue = afterRestart!;
    expect(restartedValue.transactionID, _firstID);
    expect(jsonEncode(restartedValue.envelope.value), jsonEncode(envelope));
    await reopened.close();
  });

  test('real reopen preserves rich attributes anonymous state and both orders', () async {
    final first = envelopeFixtureAccount('2', purposes: {AccountType.main, AccountType.video});
    addEnvelopeFixtureAttributes(first.cookieJar);
    final nullable = envelopeFixtureAccount('10', accessKey: null, refreshToken: null);
    final anonymous = AnonymousAccount()
      ..type.addAll(const {AccountType.video, AccountType.main});
    addEnvelopeFixtureAttributes(anonymous.cookieJar);
    await Accounts.installCredentials(first);
    await Accounts.installCredentials(nullable);
    await Accounts.refresh();
    Accounts.selectTemporarily(AccountType.heartbeat, first);
    anonymous.activated = false;
    final capture = _copy(Accounts.captureLiveMemoryShadow().value);
    final records = (capture['records']! as List).cast<Map>();
    final anonymousRecord = records[0];
    expect((anonymousRecord['jar']! as Map)['hostBuckets'], isNotEmpty);
    expect(anonymousRecord['persistedPurposes'], ['video', 'main']);
    expect(anonymousRecord['activated'], false);
    expect(records[1]['accessKeyUnits'], isNull);
    expect(records[1]['refreshTokenUnits'], isNull);
    final storedKeys = [
      for (final entry in (capture['storedOrder']! as List))
        _units((entry as Map)['keyUnits']),
    ];
    final ownerKeys = [
      for (final entry in (capture['ownerOrder']! as List))
        _units((entry as Map)['keyUnits']),
    ];
    expect(storedKeys, ['10', '2']);
    expect(ownerKeys, ['2', '10']);
    expect(storedKeys, isNot(ownerKeys));
    expect((capture['selections']! as List)[AccountType.heartbeat.index], isNot(0));

    final box = await Hive.openBox<String>(_boxName);
    final store = NativeAccountReverseRestoreStore(
      vault: HiveNativeAccountReverseRestoreVault(box),
      transactionIDFactory: () => _firstID,
    );
    await store.importRestore(
      envelope: capture, authorityEpoch: _epoch, createdAtMicroseconds: 7);
    await box.close();
    final reopened = await Hive.openBox<String>(_boxName);
    final restarted = NativeAccountReverseRestoreStore(
      vault: HiveNativeAccountReverseRestoreVault(reopened));
    final loaded = await restarted.loadRestore();
    expect(loaded, isNotNull);
    expect(jsonEncode(loaded!.envelope.value), jsonEncode(capture));
    await reopened.close();
  });

  test('candidate without a published manifest stays unpublished across a real reopen', () async {
    final first = await captureWith('2');
    final box = await Hive.openBox<String>(_boxName);
    final store = NativeAccountReverseRestoreStore(
      vault: HiveNativeAccountReverseRestoreVault(box),
      transactionIDFactory: () => _firstID,
    );
    await store.importRestore(
      envelope: first, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    await box.delete(_manifestKey);
    await box.close();

    final reopened = await Hive.openBox<String>(_boxName);
    final restarted = NativeAccountReverseRestoreStore(
      vault: HiveNativeAccountReverseRestoreVault(reopened));
    expect(await restarted.loadRestore(), isNull);
    final second = await captureWith('10');
    final receipt = await restarted.importRestore(
      envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2);
    final loaded = await restarted.loadRestore();
    final loadedValue = loaded!;
    expect(loadedValue.transactionID, receipt.transactionID);
    expect(loadedValue.envelope.value, second);
    await reopened.close();
  });

  test('duplicate transaction id never overwrites a published immutable record', () async {
    final first = await captureWith('2');
    final second = await captureWith('10');
    final vault = _FaultVault();
    final store = _faultStore(vault, id: _firstID);
    final receipt = await store.importRestore(
      envelope: first, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    final recordKey = _recordKey(_firstID);
    final originalRecord = vault.values[recordKey]!;
    final originalManifest = vault.values[_manifestKey]!;
    final removeBefore = vault.removeCalls;
    await expectLater(
      store.importRestore(
        envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'duplicateTransaction')),
    );
    expect(vault.values[recordKey], originalRecord);
    expect(vault.values[_manifestKey], originalManifest);
    expect(vault.removeCalls, removeBefore);
    final loaded = await store.loadRestore();
    expect(loaded!.transactionID, receipt.transactionID);
    expect(loaded.envelope.value, first);
  });

  test('write-before failure keeps the previous manifest and removes the candidate', () async {
    final first = await captureWith('2');
    final second = await captureWith('10');
    final vault = _FaultVault();
    const ids = [_firstID, _secondID];
    var nextId = 0;
    final store = NativeAccountReverseRestoreStore(
      vault: vault,
      transactionIDFactory: () => ids[nextId++],
    );
    final firstReceipt = await store.importRestore(
      envelope: first, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    final manifestBefore = vault.values[_manifestKey]!;
    vault.arm(_Fault.writeBefore);
    await expectLater(
      store.importRestore(
        envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2),
      throwsA(isA<StateError>()),
    );
    expect(vault.values[_manifestKey], manifestBefore);
    expect(vault.candidateCount, 1);
    expect(vault.values[_recordKey(_secondID)], isNull);
    final loaded = await store.loadRestore();
    final loadedValue = loaded!;
    expect(loadedValue.transactionID, firstReceipt.transactionID);
    expect(loadedValue.envelope.value, first);
  });

  test('record readback failure removes only the fresh unreferenced candidate', () async {
    final first = await captureWith('2');
    final second = await captureWith('10');
    final vault = _FaultVault();
    const ids = [_firstID, _secondID];
    var nextId = 0;
    final store = NativeAccountReverseRestoreStore(
      vault: vault,
      transactionIDFactory: () => ids[nextId++],
    );
    await store.importRestore(
      envelope: first, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    final manifestBefore = vault.values[_manifestKey]!;
    vault.arm(_Fault.recordReadbackError);
    await expectLater(
      store.importRestore(
        envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'verificationFailed')),
    );
    expect(vault.values[_recordKey(_secondID)], isNull);
    expect(vault.values[_manifestKey], manifestBefore);
    final loaded = await store.loadRestore();
    expect(loaded!.envelope.value, first);
  });

  test('record write-then-error is accepted only after exact readback', () async {
    final envelope = await captureWith('2');
    final vault = _FaultVault();
    final store = _faultStore(vault, id: _firstID);
    vault.arm(_Fault.recordWriteThenError);
    final receipt = await store.importRestore(
      envelope: envelope, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    expect(receipt.recoveredWriteAcknowledgment, true);
    final loaded = await store.loadRestore();
    expect(loaded!.envelope.value, envelope);
  });

  test('manifest write-then-error resolves by reread before authority is claimed', () async {
    final envelope = await captureWith('2');
    final vault = _FaultVault();
    final store = _faultStore(vault, id: _firstID);
    vault.arm(_Fault.manifestWriteThenError);
    final receipt = await store.importRestore(
      envelope: envelope, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    expect(receipt.recoveredWriteAcknowledgment, true);
    final loaded = await store.loadRestore();
    final loadedValue = loaded!;
    expect(loadedValue.transactionID, _firstID);
    expect(loadedValue.envelope.value, envelope);
  });

  test('unknown publication keeps both records and fences every store until a durable load', () async {
    final first = await captureWith('2');
    final second = await captureWith('10');
    final third = await captureWith('20');
    final vault = _FaultVault();
    const ids = [_firstID, _secondID, _thirdID];
    var nextId = 0;
    final store = NativeAccountReverseRestoreStore(
      vault: vault,
      transactionIDFactory: () => ids[nextId++],
    );
    await store.importRestore(
      envelope: first, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    vault.arm(_Fault.readAfterPublish);
    await expectLater(
      store.importRestore(
        envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'publicationUnknown')),
    );
    expect(vault.candidateCount, 2);
    final other = _faultStore(vault, id: _thirdID);
    await expectLater(
      other.importRestore(
        envelope: third, authorityEpoch: _epoch, createdAtMicroseconds: 3),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'recoveryRequired')),
    );
    final loaded = await other.loadRestore();
    expect(loaded!.envelope.value, second);
    final receipt = await other.importRestore(
      envelope: third, authorityEpoch: _epoch, createdAtMicroseconds: 3);
    final afterRecovery = await other.loadRestore();
    final recoveredValue = afterRecovery!;
    expect(recoveredValue.transactionID, receipt.transactionID);
    expect(recoveredValue.envelope.value, third);
  });

  test('stale snapshot CAS rejects without deleting the competing manifest', () async {
    final envelope = await captureWith('2');
    final vault = _FaultVault();
    final store = _faultStore(vault, id: _firstID);
    final external = jsonEncode(<String, Object?>{
      'formatVersion': 1,
      'source': 'nativeAccountReverseExport',
      'transactionID': _secondID,
      'byteCount': 1,
      'sha256': List<String>.filled(64, 'a').join(),
    });
    vault.injectManifestOnRecordWrite = external;
    await expectLater(
      store.importRestore(
        envelope: envelope, authorityEpoch: _epoch, createdAtMicroseconds: 1),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'staleSnapshot')),
    );
    expect(vault.values[_manifestKey], external);
    expect(vault.candidateCount, 0);
  });

  test('historical transaction id conflict and pre-write cancel never remove published records', () async {
    final first = await captureWith('2');
    final second = await captureWith('10');
    final third = await captureWith('20');
    final vault = _FaultVault();
    const ids = [_firstID, _secondID, _firstID];
    var nextId = 0;
    final store = NativeAccountReverseRestoreStore(
      vault: vault,
      transactionIDFactory: () => ids[nextId++],
    );
    await store.importRestore(
      envelope: first, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    await store.importRestore(
      envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2);
    final historicalRecord = vault.values[_recordKey(_firstID)]!;
    final historicalManifest = vault.values[_manifestKey]!;
    final removeBefore = vault.removeCalls;
    await expectLater(
      store.importRestore(
        envelope: third, authorityEpoch: _epoch, createdAtMicroseconds: 3),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'duplicateTransaction')),
    );
    expect(vault.removeCalls, removeBefore);
    expect(vault.values[_recordKey(_firstID)], historicalRecord);
    expect(vault.values[_manifestKey], historicalManifest);
    final loaded = await store.loadRestore();
    expect(loaded!.envelope.value, second);

    // Cancellation at the second check (after baseline, before any write) must
    // not remove anything either.
    var cancelled = false;
    vault.pauseNextRead();
    final pending = NativeAccountReverseRestoreStore(
      vault: vault,
      transactionIDFactory: () => _thirdID,
    ).importRestore(
      envelope: first, authorityEpoch: _epoch, createdAtMicroseconds: 4,
      isCancelled: () => cancelled,
    );
    await vault.paused.future;
    cancelled = true;
    vault.release();
    await expectLater(
      pending,
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'cancelled')),
    );
    expect(vault.removeCalls, removeBefore);
    expect(vault.values[_recordKey(_thirdID)], isNull);
    expect(vault.values[_recordKey(_firstID)], historicalRecord);
    expect(vault.values[_manifestKey], historicalManifest);
  });

  test('cancel before publication removes only the exclusively created candidate', () async {
    final envelope = await captureWith('2');
    final vault = _FaultVault();
    final store = _faultStore(vault, id: _firstID);
    vault.pauseNextWrite();
    var cancelled = false;
    final pending = store.importRestore(
      envelope: envelope,
      authorityEpoch: _epoch,
      createdAtMicroseconds: 1,
      isCancelled: () => cancelled,
    );
    await vault.paused.future;
    expect(vault.isPaused, true);
    cancelled = true;
    vault.release();
    await expectLater(
      pending,
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'cancelled')),
    );
    expect(vault.values, isEmpty);
    expect(vault.removeCalls, 1);
  });

  test('cleanup after a paused candidate releases the shared gate for the next publish', () async {
    final first = await captureWith('2');
    final second = await captureWith('10');
    final vault = _FaultVault();
    final storeA = _faultStore(vault, id: _firstID);
    final storeB = _faultStore(vault, id: _secondID);
    vault.pauseNextWrite();
    var cancelled = false;
    final pendingA = storeA.importRestore(
      envelope: first,
      authorityEpoch: _epoch,
      createdAtMicroseconds: 1,
      isCancelled: () => cancelled,
    );
    await vault.paused.future;
    await expectLater(
      storeB.importRestore(
        envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'operationInProgress')),
    );
    cancelled = true;
    vault.release();
    await expectLater(
      pendingA,
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'cancelled')),
    );
    expect(vault.values, isEmpty);
    final receipt = await storeB.importRestore(
      envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2);
    final loaded = await storeB.loadRestore();
    final loadedValue = loaded!;
    expect(loadedValue.transactionID, receipt.transactionID);
    expect(loadedValue.envelope.value, second);
  });

  test('two stores sharing one physical vault cannot interleave CAS and publish', () async {
    final first = await captureWith('2');
    final second = await captureWith('10');
    final vault = _FaultVault();
    final storeA = _faultStore(vault, id: _firstID);
    final storeB = _faultStore(vault, id: _secondID);
    vault.pauseNextManifestWrite();
    final pendingA = storeA.importRestore(
      envelope: first, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    await vault.paused.future;
    await expectLater(
      storeB.importRestore(
        envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'operationInProgress')),
    );
    await expectLater(
      storeB.loadRestore(),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'operationInProgress')),
    );
    vault.release();
    final receiptA = await pendingA;
    final loadedA = await storeA.loadRestore();
    expect(loadedA!.transactionID, receiptA.transactionID);
    final receiptB = await storeB.importRestore(
      envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2);
    final loadedB = await storeB.loadRestore();
    final loadedBValue = loadedB!;
    expect(loadedBValue.transactionID, receiptB.transactionID);
    expect(loadedBValue.envelope.value, second);
  });

  test('two Hive wrappers over one box share the operation gate', () async {
    final first = await captureWith('2');
    final second = await captureWith('10');
    final box = await Hive.openBox<String>(_boxName);
    final pausing = _PausingVault(HiveNativeAccountReverseRestoreVault(box));
    final storeA = NativeAccountReverseRestoreStore(
      vault: pausing,
      transactionIDFactory: () => _firstID,
    );
    final storeB = NativeAccountReverseRestoreStore(
      vault: HiveNativeAccountReverseRestoreVault(box),
      transactionIDFactory: () => _secondID,
    );
    pausing.pauseManifestWrite();
    final pendingA = storeA.importRestore(
      envelope: first, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    await pausing.paused.future;
    await expectLater(
      storeB.importRestore(
        envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'operationInProgress')),
    );
    pausing.release();
    await pendingA;
    final loadedB = await storeB.loadRestore();
    expect(loadedB, isNotNull);
    expect(loadedB!.envelope.value, first);
    final receiptB = await storeB.importRestore(
      envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 3);
    final afterB = await storeA.loadRestore();
    final afterBValue = afterB!;
    expect(afterBValue.transactionID, receiptB.transactionID);
    expect(afterBValue.envelope.value, second);
    await box.close();
  });

  test('concurrent reentry is rejected while a write awaits', () async {
    final first = await captureWith('2');
    final second = await captureWith('10');
    final vault = _FaultVault();
    final store = _faultStore(vault, id: _firstID);
    vault.pauseNextWrite();
    final pending = store.importRestore(
      envelope: first, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    await vault.paused.future;
    await expectLater(
      store.loadRestore(),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'operationInProgress')),
    );
    await expectLater(
      store.importRestore(
        envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'operationInProgress')),
    );
    vault.release();
    await pending;
    final loaded = await store.loadRestore();
    expect(loaded!.envelope.value, first);
  });

  test('invalid candidate and malformed provenance write nothing', () async {
    final envelope = await captureWith('2');
    final vault = _FaultVault();
    final store = _faultStore(vault, id: _firstID);
    final invalid = Map<String, Object?>.of(envelope)..['schemaVersion'] = 1;
    await expectLater(
      store.importRestore(
        envelope: invalid, authorityEpoch: _epoch, createdAtMicroseconds: 1),
      throwsA(isA<NativeAccountReverseImportException>()),
    );
    await expectLater(
      store.importRestore(
        envelope: envelope, authorityEpoch: '', createdAtMicroseconds: 1),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'invalidProvenance')),
    );
    await expectLater(
      store.importRestore(
        envelope: envelope, authorityEpoch: _epoch, createdAtMicroseconds: -1),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'invalidProvenance')),
    );
    expect(vault.values, isEmpty);
    expect(vault.removeCalls, 0);
  });

  test('corrupt record, invalid manifest and missing record fail closed without deletion', () async {
    final envelope = await captureWith('2');
    final vault = _FaultVault();
    final store = _faultStore(vault, id: _firstID);
    await store.importRestore(
      envelope: envelope, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    const recordKey = '${NativeAccountReverseRestoreStore.recordKeyPrefix}$_firstID';
    final record = vault.values[recordKey]!;
    vault.values[recordKey] = '$record ';
    await expectLater(
      store.loadRestore(),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'verificationFailed')),
    );
    expect(vault.values[recordKey], isNotNull);
    vault.values[recordKey] = record;
    final manifest = vault.values[_manifestKey]!;
    vault.values[_manifestKey] = '{"formatVersion":2}';
    await expectLater(
      store.loadRestore(),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'invalidManifest')),
    );
    expect(vault.values[recordKey], record);
    vault.values[_manifestKey] = 'not-json';
    await expectLater(
      store.loadRestore(),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'invalidManifest')),
    );
    expect(vault.values[recordKey], record);
    vault.values[_manifestKey] = manifest;
    await vault.remove(recordKey);
    await expectLater(
      store.loadRestore(),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'missingRecord')),
    );
  });

  test('strict persistent JSON rejects duplicates floats and budget escapes', () async {
    final envelope = await captureWith('2');
    final vault = _FaultVault();
    final store = _faultStore(vault, id: _firstID);
    await store.importRestore(
      envelope: envelope, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    const recordKey = '${NativeAccountReverseRestoreStore.recordKeyPrefix}$_firstID';
    final originalRecord = vault.values[recordKey]!;
    final originalManifest = vault.values[_manifestKey]!;

    void writePair(String record) {
      vault.values[recordKey] = record;
      final bytes = utf8.encode(record);
      vault.values[_manifestKey] = jsonEncode(<String, Object?>{
        'formatVersion': 1,
        'source': 'nativeAccountReverseExport',
        'transactionID': _firstID,
        'byteCount': bytes.length,
        'sha256': _digest(record),
      });
    }

    Future<void> expectInvalid(String code) => expectLater(
      store.loadRestore(),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', code)),
    );

    // Manifest: float version, duplicate source (plain and escaped), depth.
    vault.values[_manifestKey] = jsonEncode(<String, Object?>{
      'formatVersion': 1.0,
      'source': 'nativeAccountReverseExport',
      'transactionID': _firstID,
      'byteCount': utf8.encode(originalRecord).length,
      'sha256': _digest(originalRecord),
    });
    await expectInvalid('invalidManifest');
    final recordBytes = utf8.encode(originalRecord).length;
    vault.values[_manifestKey] =
        '{"formatVersion":1,"source":"wrong","source":"nativeAccountReverseExport",'
        '"transactionID":"$_firstID","byteCount":$recordBytes,'
        '"sha256":"${_digest(originalRecord)}"}';
    await expectInvalid('invalidManifest');
    vault.values[_manifestKey] =
        '{"formatVersion":1,"sour\\u0063e":"wrong","source":"nativeAccountReverseExport",'
        '"transactionID":"$_firstID","byteCount":$recordBytes,'
        '"sha256":"${_digest(originalRecord)}"}';
    await expectInvalid('invalidManifest');
    vault.values[_manifestKey] = List<String>.filled(12, '[').join() + 'null' +
        List<String>.filled(12, ']').join();
    await expectInvalid('invalidManifest');
    vault.values[_manifestKey] = originalManifest;

    // Record: float version, escaped duplicate, envelope nested duplicate.
    writePair(originalRecord.replaceFirst('"formatVersion":1,', '"formatVersion":1.0,'));
    await expectInvalid('invalidRecord');
    writePair(originalRecord.replaceFirst(
      '"formatVersion":1,', '"formatVersion":1,"format\\u0056ersion":1,'));
    await expectInvalid('invalidRecord');
    writePair(originalRecord.replaceFirst(
      '"scope":"coherentLiveMemoryShadow"',
      '"scope":"wrong","scope":"coherentLiveMemoryShadow"'));
    await expectInvalid('invalidRecord');

    vault.values[recordKey] = originalRecord;
    vault.values[_manifestKey] = originalManifest;
    final loaded = await store.loadRestore();
    expect(loaded, isNotNull);
    expect(loaded!.envelope.value, envelope);
  });
}

String _units(Object? raw) => String.fromCharCodes((raw! as List).cast<int>());
