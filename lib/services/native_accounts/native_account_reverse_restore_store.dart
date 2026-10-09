import 'dart:convert';

import 'package:PiliPlus/services/native_accounts/native_account_reverse_import.dart';
import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';
import 'package:uuid/v4.dart';

final class NativeAccountReverseRestoreException implements Exception {
  const NativeAccountReverseRestoreException(this.code);
  final String code;
}

final class NativeAccountReverseRestoreReceipt {
  const NativeAccountReverseRestoreReceipt({
    required this.transactionID,
    required this.recoveredWriteAcknowledgment,
  });

  final String transactionID;

  /// A write reported failure but its exact readback proved the durable value.
  final bool recoveredWriteAcknowledgment;
}

final class NativeAccountReverseRestoreResult {
  const NativeAccountReverseRestoreResult._({
    required this.transactionID,
    required this.authorityEpoch,
    required this.createdAtMicroseconds,
    required this.envelope,
  });

  final String transactionID;
  final String authorityEpoch;
  final int createdAtMicroseconds;
  final NativeAccountReverseImportResult envelope;
}

/// String-keyed persistence boundary. Production uses [HiveNativeAccountReverseRestoreVault];
/// tests inject a deterministic fault vault. Never touches the legacy account box.
abstract interface class NativeAccountReverseRestoreVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

final class HiveNativeAccountReverseRestoreVault
    implements NativeAccountReverseRestoreVault {
  const HiveNativeAccountReverseRestoreVault(this.box);

  final Box<String> box;

  @override
  Future<String?> read(String key) => Future<String?>.value(box.get(key));

  @override
  Future<void> write(String key, String value) => box.put(key, value);

  @override
  Future<void> remove(String key) => box.delete(key);
}

/// Durable candidate vault for a versioned reverse-export envelope. Protocol:
/// strict pure validation -> candidate write -> exact readback -> CAS recheck
/// -> single manifest publish -> readback. Published records are retained;
/// safe GC is deferred while references cannot be proven. This component never
/// applies state to Accounts, never switches authority and never clears or
/// merges the legacy account box.
final class NativeAccountReverseRestoreStore {
  NativeAccountReverseRestoreStore({
    required this.vault,
    String Function()? transactionIDFactory,
  }) : _newTransactionID = transactionIDFactory ?? _defaultTransactionID;

  static const formatVersion = 1;
  static const source = 'nativeAccountReverseExport';
  static const manifestKey = 'restore-manifest';
  static const recordKeyPrefix = 'restore-record.';
  static const _maxManifestBytes = 4096;
  static const _maxRecordBytes = 20 * 1024 * 1024;
  static const _manifestKeys = {
    'formatVersion', 'source', 'transactionID', 'byteCount', 'sha256',
  };
  static const _recordKeys = {
    'formatVersion', 'source', 'transactionID', 'authorityEpoch',
    'createdAtMicroseconds', 'envelope',
  };
  static final _identifierPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  static final _digestPattern = RegExp(r'^[0-9a-f]{64}$');

  final NativeAccountReverseRestoreVault vault;
  final String Function() _newTransactionID;
  bool _operationInProgress = false;
  bool _requiresRecovery = false;

  static String _defaultTransactionID() => const UuidV4().generate();

  Future<NativeAccountReverseRestoreReceipt> importRestore({
    required Map<String, Object?> envelope,
    required String authorityEpoch,
    required int createdAtMicroseconds,
    bool Function()? isCancelled,
  }) async {
    if (_operationInProgress) {
      throw const NativeAccountReverseRestoreException('operationInProgress');
    }
    _operationInProgress = true;
    String? recordKey;
    var keepRecord = false;
    try {
      if (_requiresRecovery) {
        throw const NativeAccountReverseRestoreException('recoveryRequired');
      }
      _checkCancelled(isCancelled);
      _validateProvenance(authorityEpoch, createdAtMicroseconds);
      // Strict pure validation before any persistent mutation.
      NativeAccountReverseImport.decode(envelope);
      final transactionID = _newTransactionID();
      if (!_identifierPattern.hasMatch(transactionID)) {
        throw const NativeAccountReverseRestoreException('invalidTransaction');
      }
      recordKey = '$recordKeyPrefix$transactionID';
      final recordJson = jsonEncode(<String, Object?>{
        'formatVersion': formatVersion,
        'source': source,
        'transactionID': transactionID,
        'authorityEpoch': authorityEpoch,
        'createdAtMicroseconds': createdAtMicroseconds,
        'envelope': envelope,
      });
      final bytes = utf8.encode(recordJson);
      if (bytes.length > _maxRecordBytes) {
        throw const NativeAccountReverseRestoreException('resourceLimit');
      }
      final digest = sha256.convert(bytes).toString();
      final baseline = await _readManifest();
      _checkCancelled(isCancelled);

      Object? recordError;
      try {
        await vault.write(recordKey, recordJson);
      } catch (error) {
        recordError = error;
      }
      final observedRecord = await vault.read(recordKey);
      if (observedRecord != recordJson) {
        await _tryRemove(recordKey);
        if (recordError != null && observedRecord == null) throw recordError;
        throw const NativeAccountReverseRestoreException('verificationFailed');
      }
      // CAS: the pointer may not change between the baseline read and publish.
      final current = await _readManifest();
      if (current?.json != baseline?.json) {
        await _tryRemove(recordKey);
        throw const NativeAccountReverseRestoreException('staleSnapshot');
      }
      _checkCancelled(isCancelled);

      final manifestJson = jsonEncode(<String, Object?>{
        'formatVersion': formatVersion,
        'source': source,
        'transactionID': transactionID,
        'byteCount': bytes.length,
        'sha256': digest,
      });
      Object? manifestError;
      try {
        await vault.write(manifestKey, manifestJson);
      } catch (error) {
        manifestError = error;
      }
      final observedManifest = await vault.read(manifestKey);
      if (observedManifest == manifestJson) {
        return NativeAccountReverseRestoreReceipt(
          transactionID: transactionID,
          recoveredWriteAcknowledgment: recordError != null || manifestError != null,
        );
      }
      if (manifestError != null && observedManifest == baseline?.json) {
        await _tryRemove(recordKey);
        throw manifestError;
      }
      // The pointer may now reference the candidate; never delete either side.
      keepRecord = true;
      _requiresRecovery = true;
      throw const NativeAccountReverseRestoreException('publicationUnknown');
    } catch (_) {
      if (!keepRecord && recordKey != null) await _tryRemove(recordKey);
      rethrow;
    } finally {
      _operationInProgress = false;
    }
  }

  /// Durable truth reader and recovery barrier. Also resolves a previous
  /// unknown publication: only a successful read re-opens `importRestore`.
  Future<NativeAccountReverseRestoreResult?> loadRestore() async {
    if (_operationInProgress) {
      throw const NativeAccountReverseRestoreException('operationInProgress');
    }
    _operationInProgress = true;
    try {
      final manifest = await _readManifest();
      if (manifest == null) {
        _requiresRecovery = false;
        return null;
      }
      final recordKey = '$recordKeyPrefix${manifest.value.transactionID}';
      final record = await vault.read(recordKey);
      if (record == null) {
        throw const NativeAccountReverseRestoreException('missingRecord');
      }
      final bytes = utf8.encode(record);
      if (bytes.length != manifest.value.byteCount ||
          sha256.convert(bytes).toString() != manifest.value.sha256) {
        throw const NativeAccountReverseRestoreException('verificationFailed');
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(record);
      } on FormatException {
        throw const NativeAccountReverseRestoreException('invalidRecord');
      }
      if (decoded is! Map) {
        throw const NativeAccountReverseRestoreException('invalidRecord');
      }
      final fields = decoded.cast<String, Object?>();
      if (fields.length != _recordKeys.length ||
          !_recordKeys.every(fields.containsKey) ||
          fields['formatVersion'] != formatVersion ||
          fields['source'] != source ||
          fields['transactionID'] != manifest.value.transactionID) {
        throw const NativeAccountReverseRestoreException('invalidRecord');
      }
      final authorityEpoch = fields['authorityEpoch'];
      final createdAtMicroseconds = fields['createdAtMicroseconds'];
      final envelope = fields['envelope'];
      if (authorityEpoch is! String || createdAtMicroseconds is! int ||
          envelope is! Map || envelope.keys.any((key) => key is! String)) {
        throw const NativeAccountReverseRestoreException('invalidRecord');
      }
      _validateProvenance(authorityEpoch, createdAtMicroseconds);
      final result = NativeAccountReverseImport.decode(
        envelope.cast<String, Object?>(),
      );
      _requiresRecovery = false;
      return NativeAccountReverseRestoreResult._(
        transactionID: manifest.value.transactionID,
        authorityEpoch: authorityEpoch,
        createdAtMicroseconds: createdAtMicroseconds,
        envelope: result,
      );
    } finally {
      _operationInProgress = false;
    }
  }

  Future<({String json, _Manifest value})?> _readManifest() async {
    final json = await vault.read(manifestKey);
    if (json == null) return null;
    if (utf8.encode(json).length > _maxManifestBytes) {
      throw const NativeAccountReverseRestoreException('invalidManifest');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      throw const NativeAccountReverseRestoreException('invalidManifest');
    }
    if (decoded is! Map) {
      throw const NativeAccountReverseRestoreException('invalidManifest');
    }
    final fields = decoded.cast<String, Object?>();
    if (fields.length != _manifestKeys.length ||
        !_manifestKeys.every(fields.containsKey) ||
        fields['formatVersion'] != formatVersion ||
        fields['source'] != source) {
      throw const NativeAccountReverseRestoreException('invalidManifest');
    }
    final transactionID = fields['transactionID'];
    final byteCount = fields['byteCount'];
    final digest = fields['sha256'];
    if (transactionID is! String || !_identifierPattern.hasMatch(transactionID) ||
        byteCount is! int || byteCount <= 0 || byteCount > _maxRecordBytes ||
        digest is! String || !_digestPattern.hasMatch(digest)) {
      throw const NativeAccountReverseRestoreException('invalidManifest');
    }
    return (
      json: json,
      value: _Manifest(
        transactionID: transactionID,
        byteCount: byteCount,
        sha256: digest,
      ),
    );
  }

  static void _validateProvenance(String authorityEpoch, int createdAtMicroseconds) {
    if (authorityEpoch.isEmpty || authorityEpoch.length > 128 ||
        authorityEpoch.codeUnits.any((unit) => unit < 32 || unit > 126) ||
        createdAtMicroseconds < 0) {
      throw const NativeAccountReverseRestoreException('invalidProvenance');
    }
  }

  static void _checkCancelled(bool Function()? isCancelled) {
    if (isCancelled?.call() == true) {
      throw const NativeAccountReverseRestoreException('cancelled');
    }
  }

  Future<void> _tryRemove(String key) async {
    try {
      await vault.remove(key);
    } catch (_) {
      // Best effort for an unreferenced candidate only; a referenced record is
      // never passed here and safe GC stays deferred.
    }
  }
}

final class _Manifest {
  const _Manifest({
    required this.transactionID,
    required this.byteCount,
    required this.sha256,
  });

  final String transactionID;
  final int byteCount;
  final String sha256;
}
