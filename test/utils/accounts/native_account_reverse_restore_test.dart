import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/services/native_accounts/native_account_reverse_import.dart';
import 'package:PiliPlus/services/native_accounts/native_account_reverse_restore_store.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'account_test_storage.dart';
import 'native_account_envelope_fixtures.dart';

const _boxName = 'account_reverse_restore';
const _epoch = 'synthetic-authority-epoch';
const _firstID = '11111111-1111-4111-8111-111111111111';
const _secondID = '22222222-2222-4222-8222-222222222222';
const _thirdID = '33333333-3333-4333-8333-333333333333';

Map<String, Object?> _copy(Map<String, Object?> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();

enum _Fault {
  writeBefore,
  recordWriteThenError,
  manifestWriteThenError,
  readAfterPublish,
}

final class _FaultVault implements NativeAccountReverseRestoreVault {
  final values = <String, String>{};
  final paused = Completer<void>();
  _Fault? fault;
  String? injectManifestOnRecordWrite;
  bool _pause = false;
  bool _manifestWritten = false;
  Completer<void>? _suspended;

  int get candidateCount => values.keys
      .where((key) => key.startsWith(NativeAccountReverseRestoreStore.recordKeyPrefix))
      .length;

  void arm(_Fault next) {
    fault = next;
    _manifestWritten = false;
  }

  void pauseNextWrite() => _pause = true;
  bool get isPaused => _suspended != null;

  void release() {
    _suspended?.complete();
    _suspended = null;
  }

  @override
  Future<String?> read(String key) {
    if (key == NativeAccountReverseRestoreStore.manifestKey &&
        _manifestWritten && fault == _Fault.readAfterPublish) {
      fault = null;
      return Future<String?>.error(StateError('synthetic lost manifest readback'));
    }
    return Future<String?>.value(values[key]);
  }

  @override
  Future<void> write(String key, String value) async {
    if (_pause) {
      _pause = false;
      final suspended = Completer<void>();
      _suspended = suspended;
      if (!paused.isCompleted) paused.complete();
      await suspended.future;
    }
    if (fault == _Fault.writeBefore) {
      fault = null;
      throw StateError('synthetic write-before');
    }
    values[key] = value;
    if (key == NativeAccountReverseRestoreStore.manifestKey) {
      _manifestWritten = true;
      if (fault == _Fault.manifestWriteThenError) {
        fault = null;
        throw StateError('synthetic manifest write-then-error');
      }
    } else {
      final injected = injectManifestOnRecordWrite;
      if (injected != null) {
        values[NativeAccountReverseRestoreStore.manifestKey] = injected;
        injectManifestOnRecordWrite = null;
      }
      if (fault == _Fault.recordWriteThenError) {
        fault = null;
        throw StateError('synthetic record write-then-error');
      }
    }
  }

  @override
  Future<void> remove(String key) {
    values.remove(key);
    return Future<void>.value();
  }
}

NativeAccountReverseRestoreStore _store(_FaultVault vault, {String? id}) =>
    NativeAccountReverseRestoreStore(
      vault: vault,
      transactionIDFactory: id == null ? null : () => id,
    );

void main() {
  late AccountTestStorage storage;
  setUpAll(() async { storage = await AccountTestStorage.open(); });
  setUp(() async {
    await storage.reset();
    final box = await Hive.openBox<String>(_boxName);
    await box.clear();
    await box.close();
  });
  tearDownAll(() => storage.close());

  Future<Map<String, Object?>> captureWith(String key) async {
    await Accounts.installCredentials(envelopeFixtureAccount(key));
    return _copy(Accounts.captureLiveMemoryShadow().value);
  }

  test('real Hive vault survives close and reopen and leaves the legacy box untouched', () async {
    final envelope = await captureWith('2');
    final legacyBefore = Accounts.account.toMap().keys.toList();
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
    expect(Accounts.account.toMap().keys.toList(), legacyBefore);
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

  test('candidate without a published manifest stays unpublished across a real reopen', () async {
    final first = await captureWith('2');
    final box = await Hive.openBox<String>(_boxName);
    final store = NativeAccountReverseRestoreStore(
      vault: HiveNativeAccountReverseRestoreVault(box),
      transactionIDFactory: () => _firstID,
    );
    await store.importRestore(
      envelope: first, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    await box.delete(NativeAccountReverseRestoreStore.manifestKey);
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

  test('write-before failure keeps the previous manifest and removes the candidate', () async {
    final first = await captureWith('2');
    final second = await captureWith('10');
    final vault = _FaultVault();
    final store = _store(vault, id: _firstID);
    final firstReceipt = await store.importRestore(
      envelope: first, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    final manifestBefore = vault.values[NativeAccountReverseRestoreStore.manifestKey];
    vault.arm(_Fault.writeBefore);
    await expectLater(
      store.importRestore(
        envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2),
      throwsA(isA<StateError>()),
    );
    expect(vault.values[NativeAccountReverseRestoreStore.manifestKey], manifestBefore);
    expect(vault.candidateCount, 1);
    final loaded = await store.loadRestore();
    final loadedValue = loaded!;
    expect(loadedValue.transactionID, firstReceipt.transactionID);
    expect(loadedValue.envelope.value, first);
  });

  test('record write-then-error is accepted only after exact readback', () async {
    final envelope = await captureWith('2');
    final vault = _FaultVault();
    final store = _store(vault, id: _firstID);
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
    final store = _store(vault, id: _firstID);
    vault.arm(_Fault.manifestWriteThenError);
    final receipt = await store.importRestore(
      envelope: envelope, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    expect(receipt.recoveredWriteAcknowledgment, true);
    final loaded = await store.loadRestore();
    final loadedValue = loaded!;
    expect(loadedValue.transactionID, _firstID);
    expect(loadedValue.envelope.value, envelope);
  });

  test('unknown publication keeps both records and fences imports until a durable load', () async {
    final first = await captureWith('2');
    final second = await captureWith('10');
    final third = await captureWith('20');
    final vault = _FaultVault();
    final ids = [_firstID, _secondID, _thirdID];
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
    await expectLater(
      store.importRestore(
        envelope: third, authorityEpoch: _epoch, createdAtMicroseconds: 3),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'recoveryRequired')),
    );
    final loaded = await store.loadRestore();
    expect(loaded!.envelope.value, second);
    final receipt = await store.importRestore(
      envelope: third, authorityEpoch: _epoch, createdAtMicroseconds: 3);
    final afterRecovery = await store.loadRestore();
    final recoveredValue = afterRecovery!;
    expect(recoveredValue.transactionID, receipt.transactionID);
    expect(recoveredValue.envelope.value, third);
  });

  test('stale snapshot CAS rejects without deleting the competing manifest', () async {
    final envelope = await captureWith('2');
    final vault = _FaultVault();
    final store = _store(vault, id: _firstID);
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
    expect(vault.values[NativeAccountReverseRestoreStore.manifestKey], external);
    expect(vault.candidateCount, 0);
  });

  test('cancel before publication removes only the unreferenced candidate', () async {
    final envelope = await captureWith('2');
    final vault = _FaultVault();
    final store = _store(vault, id: _firstID);
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
  });

  test('concurrent reentry is rejected while a write awaits', () async {
    final first = await captureWith('2');
    final second = await captureWith('10');
    final vault = _FaultVault();
    final store = _store(vault, id: _firstID);
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
    final store = _store(vault, id: _firstID);
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
  });

  test('corrupt record, invalid manifest and missing record fail closed without deletion', () async {
    final envelope = await captureWith('2');
    final vault = _FaultVault();
    final store = _store(vault, id: _firstID);
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
    final manifest = vault.values[NativeAccountReverseRestoreStore.manifestKey]!;
    vault.values[NativeAccountReverseRestoreStore.manifestKey] = '{"formatVersion":2}';
    await expectLater(
      store.loadRestore(),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'invalidManifest')),
    );
    expect(vault.values[recordKey], record);
    vault.values[NativeAccountReverseRestoreStore.manifestKey] = 'not-json';
    await expectLater(
      store.loadRestore(),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'invalidManifest')),
    );
    expect(vault.values[recordKey], record);
    vault.values[NativeAccountReverseRestoreStore.manifestKey] = manifest;
    await vault.remove(recordKey);
    await expectLater(
      store.loadRestore(),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'missingRecord')),
    );
  });
}
