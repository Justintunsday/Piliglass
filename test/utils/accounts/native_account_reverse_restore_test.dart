import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/native_account_reverse_import.dart';
import 'package:PiliPlus/services/native_accounts/native_account_reverse_restore_store.dart';
import 'package:PiliPlus/services/native_accounts/strict_persistent_json.dart';
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
  String? _injectRecordKey;
  String? _injectRecord;
  String? _injectManifest;
  bool _pauseWrite = false;
  bool _pauseRead = false;
  bool _pauseManifestWrite = false;
  bool _pauseReadAfterRecordWrite = false;
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
  void pauseNextReadAfterRecordWrite() {
    _pauseReadAfterRecordWrite = true;
    _recordWrites = 0;
  }

  /// Installs a complete, independently published competing candidate as soon
  /// as this round writes its own record, making the final CAS see a different
  /// pointer whose record is fully loadable.
  void injectCompetingCandidate({
    required String recordKey,
    required String record,
    required String manifest,
  }) {
    _injectRecordKey = recordKey;
    _injectRecord = record;
    _injectManifest = manifest;
  }

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
    if (_pauseReadAfterRecordWrite && _recordWrites > 0 && key != _manifestKey) {
      _pauseReadAfterRecordWrite = false;
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
      final injectedKey = _injectRecordKey;
      if (injectedKey != null) {
        values[injectedKey] = _injectRecord!;
        values[_manifestKey] = _injectManifest!;
        _injectRecordKey = null;
        _injectRecord = null;
        _injectManifest = null;
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
/// or read pause for interleaving and caller-mutation tests.
final class _PausingVault implements NativeAccountReverseRestoreVault {
  _PausingVault(this.inner);

  final NativeAccountReverseRestoreVault inner;
  final paused = Completer<void>();
  bool _pauseManifest = false;
  bool _pauseRead = false;
  Completer<void>? _suspended;

  @override
  Object get coordinationDomain => inner.coordinationDomain;

  void pauseManifestWrite() => _pauseManifest = true;
  void pauseNextRead() => _pauseRead = true;

  void release() {
    _suspended?.complete();
    _suspended = null;
  }

  @override
  Future<String?> read(String key) async {
    if (_pauseRead) {
      _pauseRead = false;
      final suspended = Completer<void>();
      _suspended = suspended;
      if (!paused.isCompleted) paused.complete();
      await suspended.future;
    }
    return inner.read(key);
  }

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

/// Domain identity constraint probe: a primitive cannot be a stable object
/// identity for the weak-key registry.
final class _StringDomainVault implements NativeAccountReverseRestoreVault {
  @override
  Object get coordinationDomain => 'string-domain';

  @override
  Future<String?> read(String key) => Future<String?>.value();

  @override
  Future<void> write(String key, String value) => Future<void>.value();

  @override
  Future<void> remove(String key) => Future<void>.value();
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
    // Frozen content oracle: in-place mutation would change both sides if the
    // after state were serialized against the same mutable objects.
    final legacyContentBefore = {
      for (final entry in legacyBefore.entries) entry.key: jsonEncode(entry.value.toJson()),
    };
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
      expect(jsonEncode(legacyAfter[key]!.toJson()), legacyContentBefore[key]);
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

  test('real reopen keeps the pre-call snapshot despite in-flight caller mutation', () async {
    final envelope = _copy(await captureWith('2'));
    final snapshot = jsonEncode(envelope);
    final box = await Hive.openBox<String>(_boxName);
    final pausing = _PausingVault(HiveNativeAccountReverseRestoreVault(box));
    final store = NativeAccountReverseRestoreStore(
      vault: pausing,
      transactionIDFactory: () => _firstID,
    );
    pausing.pauseNextRead();
    final pending = store.importRestore(
      envelope: envelope, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    await pausing.paused.future;
    envelope['revision'] = -1;
    envelope['durabilityVerified'] = true;
    final records = (envelope['records']! as List).cast<Map>();
    ((records[1]['jar']! as Map)['hostBuckets'] as List).clear();
    pausing.release();
    await pending;
    await box.close();

    final reopened = await Hive.openBox<String>(_boxName);
    final restarted = NativeAccountReverseRestoreStore(
      vault: HiveNativeAccountReverseRestoreVault(reopened));
    final loaded = await restarted.loadRestore();
    expect(loaded, isNotNull);
    expect(jsonEncode(loaded!.envelope.value), snapshot);
    expect(loaded.envelope.value['revision'], isNot(-1));
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

  test('caller mutation during the create-only read cannot change the reserved snapshot', () async {
    final envelope = _copy(await captureWith('2'));
    final snapshot = jsonEncode(envelope);
    final vault = _FaultVault();
    final store = _faultStore(vault, id: _firstID);
    vault.pauseNextRead();
    final pending = store.importRestore(
      envelope: envelope, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    await vault.paused.future;
    // Top-level and nested in-place mutations after validation, before write.
    envelope['schemaVersion'] = 1;
    envelope['nativeWritesAllowed'] = true;
    final records = (envelope['records']! as List).cast<Map>();
    records[1]['mid'] = -1;
    final jar = records[1]['jar']! as Map;
    ((jar['domainBuckets']! as List).first as Map)['keyUnits'] = [9999];
    vault.release();
    final receipt = await pending;
    expect(receipt.transactionID, _firstID);
    final record = jsonDecode(vault.values[_recordKey(_firstID)]!) as Map<String, Object?>;
    expect(record['envelope'], jsonDecode(snapshot));
    final loaded = await store.loadRestore();
    expect(loaded, isNotNull);
    expect(jsonEncode(loaded!.envelope.value), snapshot);
    expect(loaded.envelope.value['schemaVersion'], 2);
    expect(loaded.envelope.value['nativeWritesAllowed'], false);
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

  test('stale snapshot CAS rejects while a complete competing candidate stays loadable', () async {
    final first = await captureWith('2');
    final second = await captureWith('10');
    // Publish one complete candidate independently, then inject both its record
    // and manifest as the competing pointer; it must remain loadable afterwards.
    final competingVault = _FaultVault();
    final competingStore = NativeAccountReverseRestoreStore(
      vault: competingVault,
      transactionIDFactory: () => _secondID,
    );
    await competingStore.importRestore(
      envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2);
    final competingRecord = competingVault.values[_recordKey(_secondID)]!;
    final competingManifest = competingVault.values[_manifestKey]!;

    final vault = _FaultVault();
    final store = _faultStore(vault, id: _firstID);
    vault.injectCompetingCandidate(
      recordKey: _recordKey(_secondID),
      record: competingRecord,
      manifest: competingManifest,
    );
    await expectLater(
      store.importRestore(
        envelope: first, authorityEpoch: _epoch, createdAtMicroseconds: 1),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'staleSnapshot')),
    );
    expect(vault.values[_manifestKey], competingManifest);
    expect(vault.values[_recordKey(_secondID)], competingRecord);
    expect(vault.values[_recordKey(_firstID)], isNull);
    final loaded = await store.loadRestore();
    expect(loaded, isNotNull);
    expect(loaded!.transactionID, _secondID);
    expect(loaded.envelope.value, second);
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

  test('cancel after the candidate write but before pointer publication keeps the published baseline', () async {
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
    final baselineRecord = vault.values[_recordKey(_firstID)]!;
    final baselineManifest = vault.values[_manifestKey]!;
    vault.pauseNextReadAfterRecordWrite();
    var cancelled = false;
    final pending = store.importRestore(
      envelope: second,
      authorityEpoch: _epoch,
      createdAtMicroseconds: 2,
      isCancelled: () => cancelled,
    );
    await vault.paused.future;
    expect(vault.values[_recordKey(_secondID)], isNotNull);
    cancelled = true;
    vault.release();
    await expectLater(
      pending,
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'cancelled')),
    );
    expect(vault.values[_recordKey(_secondID)], isNull);
    expect(vault.values[_recordKey(_firstID)], baselineRecord);
    expect(vault.values[_manifestKey], baselineManifest);
    final loaded = await store.loadRestore();
    expect(loaded!.envelope.value, first);
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

  test('coordinationDomain must be a stable object identity', () {
    expect(() => NativeAccountReverseRestoreStore(vault: _StringDomainVault()),
      throwsStateError);
  });

  test('distinct object domains keep independent gates and recovery fences', () async {
    final first = await captureWith('2');
    final second = await captureWith('10');
    final vaultA = _FaultVault();
    final vaultB = _FaultVault();
    final storeA = _faultStore(vaultA, id: _firstID);
    await storeA.importRestore(
      envelope: first, authorityEpoch: _epoch, createdAtMicroseconds: 1);
    vaultA.arm(_Fault.readAfterPublish);
    await expectLater(
      storeA.importRestore(
        envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2),
      throwsA(isA<NativeAccountReverseRestoreException>()
        .having((error) => error.code, 'code', 'publicationUnknown')),
    );
    final storeB = _faultStore(vaultB, id: _secondID);
    final receipt = await storeB.importRestore(
      envelope: second, authorityEpoch: _epoch, createdAtMicroseconds: 2);
    final loaded = await storeB.loadRestore();
    final loadedValue = loaded!;
    expect(loadedValue.transactionID, receipt.transactionID);
    expect(loadedValue.envelope.value, second);
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
    vault.values[_manifestKey] =
        '${List<String>.filled(12, '[').join()}null${List<String>.filled(12, ']').join()}';
    await expectInvalid('invalidManifest');
    vault.values[_manifestKey] =
        List<String>.filled(5000, 'x').join();
    await expectInvalid('invalidManifest');
    vault.values[_manifestKey] = originalManifest;

    // Record: float version, escaped duplicate, envelope nested duplicate and
    // an over-deep tree; each with a matching digest/byteCount.
    writePair(originalRecord.replaceFirst('"formatVersion":1,', '"formatVersion":1.0,'));
    await expectInvalid('invalidRecord');
    writePair(originalRecord.replaceFirst(
      '"formatVersion":1,', '"formatVersion":1,"format\\u0056ersion":1,'));
    await expectInvalid('invalidRecord');
    writePair(originalRecord.replaceFirst(
      '"scope":"coherentLiveMemoryShadow"',
      '"scope":"wrong","scope":"coherentLiveMemoryShadow"'));
    await expectInvalid('invalidRecord');
    final deep = '${List<String>.filled(45, '[').join()}null'
        '${List<String>.filled(45, ']').join()}';
    writePair('{"formatVersion":1,"source":"nativeAccountReverseExport",'
        '"transactionID":"$_firstID","authorityEpoch":"$_epoch",'
        '"createdAtMicroseconds":1,"envelope":$deep}');
    await expectInvalid('invalidRecord');

    vault.values[recordKey] = originalRecord;
    vault.values[_manifestKey] = originalManifest;
    final loaded = await store.loadRestore();
    expect(loaded, isNotNull);
    expect(loaded!.envelope.value, envelope);
  });

  test('strict persistent JSON enforces budgets escapes and integers directly', () {
    Matcher code(String value) => isA<StrictPersistentJsonException>()
        .having((error) => error.code, 'code', value);
    expect(() => StrictPersistentJson.parse('[]',
      maxCodeUnits: 1, maxDepth: 8, maxNodes: 8), throwsA(code('codeUnitLimit')));
    expect(() => StrictPersistentJson.parse('[[[null]]]',
      maxCodeUnits: 64, maxDepth: 2, maxNodes: 64), throwsA(code('depthLimit')));
    expect(() => StrictPersistentJson.parse('[1,2,3]',
      maxCodeUnits: 64, maxDepth: 8, maxNodes: 2), throwsA(code('nodeLimit')));
    expect(() => StrictPersistentJson.parse('"\\q"',
      maxCodeUnits: 64, maxDepth: 8, maxNodes: 8), throwsA(code('invalidEscape')));
    expect(() => StrictPersistentJson.parse('{"a":1,"a":2}',
      maxCodeUnits: 64, maxDepth: 8, maxNodes: 8), throwsA(code('duplicateKey')));
    expect(() => StrictPersistentJson.parse('01',
      maxCodeUnits: 64, maxDepth: 8, maxNodes: 8), throwsA(code('invalidNumber')));
    expect(() => StrictPersistentJson.parse('1.0',
      maxCodeUnits: 64, maxDepth: 8, maxNodes: 8), throwsA(code('nonIntegerNumber')));
    expect(() => StrictPersistentJson.parse('{} trailing',
      maxCodeUnits: 64, maxDepth: 8, maxNodes: 8), throwsA(code('trailingData')));
    expect(StrictPersistentJson.parse('{"a":[1,true,null,-2]}',
      maxCodeUnits: 64, maxDepth: 8, maxNodes: 16), {
      'a': [1, true, null, -2],
    });
  });
}

String _units(Object? raw) => String.fromCharCodes((raw! as List).cast<int>());
