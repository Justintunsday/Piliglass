import 'dart:convert';

import 'package:PiliPlus/services/native_accounts/native_account_reverse_import.dart';
import 'package:PiliPlus/services/native_accounts/strict_persistent_json.dart';
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
  /// Physical storage identity. Stores sharing a domain share one operation
  /// gate, recovery fence and transaction-ID reservation set.
  Object get coordinationDomain;

  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

final class HiveNativeAccountReverseRestoreVault
    implements NativeAccountReverseRestoreVault {
  const HiveNativeAccountReverseRestoreVault(this.box, {Object? coordinationDomain})
      : _coordinationDomain = coordinationDomain;

  final Box<String> box;
  final Object? _coordinationDomain;

  @override
  Object get coordinationDomain => _coordinationDomain ?? box;

  @override
  Future<String?> read(String key) => Future<String?>.value(box.get(key));

  @override
  Future<void> write(String key, String value) => box.put(key, value);

  @override
  Future<void> remove(String key) => box.delete(key);
}

/// Durable candidate vault for a versioned reverse-export envelope. Protocol:
/// reserve a create-only transaction ID -> strict pure validation -> candidate
/// write -> exact readback -> CAS recheck -> single manifest publish ->
/// readback. Published records are retained; safe GC is deferred while
/// references cannot be proven. This component never applies state to
/// Accounts, never switches authority and never clears or merges the legacy
/// account box.
final class NativeAccountReverseRestoreStore {
  NativeAccountReverseRestoreStore({
    required this.vault,
    String Function()? transactionIDFactory,
  })  : _newTransactionID = transactionIDFactory ?? _defaultTransactionID,
        _domain = _RestoreDomain.of(vault.coordinationDomain);

  static const formatVersion = 1;
  static const source = 'nativeAccountReverseExport';
  static const manifestKey = 'restore-manifest';
  static const recordKeyPrefix = 'restore-record.';
  static const _maxManifestBytes = 4096;
  static const _maxRecordBytes = 20 * 1024 * 1024;
  static const _manifestDepth = 8;
  static const _manifestNodes = 256;
  static const _recordDepth = 40;
  static const _recordNodes = 3 * 1024 * 1024 + 65536;
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
  final _RestoreDomain _domain;

  static String _defaultTransactionID() => const UuidV4().generate();

  Future<NativeAccountReverseRestoreReceipt> importRestore({
    required Map<String, Object?> envelope,
    required String authorityEpoch,
    required int createdAtMicroseconds,
    bool Function()? isCancelled,
  }) async {
    if (_domain.operationInProgress) {
      throw const NativeAccountReverseRestoreException('operationInProgress');
    }
    _domain.operationInProgress = true;
    String? transactionID;
    // Only a candidate this round exclusively reserved (create-only) and for
    // which a write was attempted may ever be cleaned up.
    var ownsCandidate = false;
    var recordAttempted = false;
    var keepRecord = false;
    try {
      if (_domain.requiresRecovery) {
        throw const NativeAccountReverseRestoreException('recoveryRequired');
      }
      _checkCancelled(isCancelled);
      _validateProvenance(authorityEpoch, createdAtMicroseconds);
      // Strict pure validation before any persistent mutation.
      NativeAccountReverseImport.decode(envelope);
      transactionID = _newTransactionID();
      if (!_identifierPattern.hasMatch(transactionID)) {
        throw const NativeAccountReverseRestoreException('invalidTransaction');
      }
      final recordKey = '$recordKeyPrefix$transactionID';
      // Create-only reservation at the shared persistent boundary: an existing
      // immutable record or an in-flight reservation must never be overwritten.
      if (_domain.reservedTransactions.contains(transactionID) ||
          await vault.read(recordKey) != null) {
        throw const NativeAccountReverseRestoreException('duplicateTransaction');
      }
      _domain.reservedTransactions.add(transactionID);
      ownsCandidate = true;
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
      recordAttempted = true;
      try {
        await vault.write(recordKey, recordJson);
      } catch (error) {
        recordError = error;
      }
      final String? observedRecord;
      try {
        observedRecord = await vault.read(recordKey);
      } catch (_) {
        throw const NativeAccountReverseRestoreException('verificationFailed');
      }
      if (observedRecord != recordJson) {
        if (recordError != null && observedRecord == null) throw recordError;
        throw const NativeAccountReverseRestoreException('verificationFailed');
      }
      // CAS: the shared gate makes this read+write exclusive per domain.
      final current = await _readManifest();
      if (current?.json != baseline?.json) {
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
      final String? observedManifest;
      try {
        observedManifest = await vault.read(manifestKey);
      } catch (_) {
        // The pointer cannot be read; neither side may be assumed unwritten.
        keepRecord = true;
        _domain.requiresRecovery = true;
        throw const NativeAccountReverseRestoreException('publicationUnknown');
      }
      if (observedManifest == manifestJson) {
        return NativeAccountReverseRestoreReceipt(
          transactionID: transactionID,
          recoveredWriteAcknowledgment: recordError != null || manifestError != null,
        );
      }
      if (manifestError != null && observedManifest == baseline?.json) {
        throw manifestError;
      }
      // The pointer may now reference the candidate; never delete either side.
      keepRecord = true;
      _domain.requiresRecovery = true;
      throw const NativeAccountReverseRestoreException('publicationUnknown');
    } catch (_) {
      if (!keepRecord && ownsCandidate && recordAttempted && transactionID != null) {
        await _removeUnreferencedCandidate(transactionID);
      }
      rethrow;
    } finally {
      if (transactionID != null) {
        _domain.reservedTransactions.remove(transactionID);
      }
      _domain.operationInProgress = false;
    }
  }

  /// Durable truth reader and recovery barrier. Also resolves a previous
  /// unknown publication: only a successful durable read re-opens
  /// `importRestore` for the shared domain. A corrupt manifest or record fails
  /// closed without changing the fence (existing semantics are preserved).
  Future<NativeAccountReverseRestoreResult?> loadRestore() async {
    if (_domain.operationInProgress) {
      throw const NativeAccountReverseRestoreException('operationInProgress');
    }
    _domain.operationInProgress = true;
    try {
      final manifest = await _readManifest();
      if (manifest == null) {
        _domain.requiresRecovery = false;
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
      final fields = _parseJson(
        record,
        maxCodeUnits: _maxRecordBytes,
        maxDepth: _recordDepth,
        maxNodes: _recordNodes,
        errorCode: 'invalidRecord',
      );
      if (fields.length != _recordKeys.length ||
          !_recordKeys.every(fields.containsKey) ||
          fields['formatVersion'] is! int ||
          fields['formatVersion'] != formatVersion ||
          fields['source'] is! String ||
          fields['source'] != source ||
          fields['transactionID'] != manifest.value.transactionID) {
        throw const NativeAccountReverseRestoreException('invalidRecord');
      }
      final authorityEpoch = fields['authorityEpoch'];
      final createdAtMicroseconds = fields['createdAtMicroseconds'];
      final envelope = fields['envelope'];
      if (authorityEpoch is! String || createdAtMicroseconds is! int ||
          envelope is! Map<String, Object?>) {
        throw const NativeAccountReverseRestoreException('invalidRecord');
      }
      _validateProvenance(authorityEpoch, createdAtMicroseconds);
      final result = NativeAccountReverseImport.decode(envelope);
      _domain.requiresRecovery = false;
      return NativeAccountReverseRestoreResult._(
        transactionID: manifest.value.transactionID,
        authorityEpoch: authorityEpoch,
        createdAtMicroseconds: createdAtMicroseconds,
        envelope: result,
      );
    } finally {
      _domain.operationInProgress = false;
    }
  }

  Future<({String json, _Manifest value})?> _readManifest() async {
    final json = await vault.read(manifestKey);
    if (json == null) return null;
    if (utf8.encode(json).length > _maxManifestBytes) {
      throw const NativeAccountReverseRestoreException('invalidManifest');
    }
    final fields = _parseJson(
      json,
      maxCodeUnits: _maxManifestBytes,
      maxDepth: _manifestDepth,
      maxNodes: _manifestNodes,
      errorCode: 'invalidManifest',
    );
    if (fields.length != _manifestKeys.length ||
        !_manifestKeys.every(fields.containsKey) ||
        fields['formatVersion'] is! int ||
        fields['formatVersion'] != formatVersion ||
        fields['source'] is! String ||
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

  static Map<String, Object?> _parseJson(
    String source, {
    required int maxCodeUnits,
    required int maxDepth,
    required int maxNodes,
    required String errorCode,
  }) {
    final Object? decoded;
    try {
      decoded = StrictPersistentJson.parse(
        source,
        maxCodeUnits: maxCodeUnits,
        maxDepth: maxDepth,
        maxNodes: maxNodes,
      );
    } on StrictPersistentJsonException {
      throw NativeAccountReverseRestoreException(errorCode);
    }
    if (decoded is! Map<String, Object?>) {
      throw NativeAccountReverseRestoreException(errorCode);
    }
    return decoded;
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

  /// Removes a candidate only when no durable manifest references it. When the
  /// reference cannot be read the record is retained; safe GC stays deferred.
  Future<void> _removeUnreferencedCandidate(String transactionID) async {
    if (await _isReferenced(transactionID)) return;
    try {
      await vault.remove('$recordKeyPrefix$transactionID');
    } catch (_) {
      // Best effort for an exclusively created, unreferenced candidate only.
    }
  }

  Future<bool> _isReferenced(String transactionID) async {
    final ({String json, _Manifest value})? manifest;
    try {
      manifest = await _readManifest();
    } catch (_) {
      // Cannot prove that the candidate is unreferenced.
      return true;
    }
    return manifest?.value.transactionID == transactionID;
  }
}

/// Shared per physical vault/namespace coordination: one operation gate, one
/// recovery fence and one transaction-ID reservation set for every store over
/// the same domain. A per-store lock cannot make the final CAS+publish atomic.
final class _RestoreDomain {
  _RestoreDomain._();

  static final Map<Object, _RestoreDomain> _domains = <Object, _RestoreDomain>{};

  static _RestoreDomain of(Object key) =>
      _domains.putIfAbsent(key, _RestoreDomain._);

  bool operationInProgress = false;
  bool requiresRecovery = false;
  final Set<String> reservedTransactions = <String>{};
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
