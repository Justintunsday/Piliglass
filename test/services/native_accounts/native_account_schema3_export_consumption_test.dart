import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/native_accounts/native_account_reverse_import.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cross-runtime consumption of the actual Swift-produced schema-3 export.
///
/// This file deliberately lives OUTSIDE `test/utils/accounts/` (which runs
/// before the Swift producer) and is analyzed and executed only by the envelope
/// pipeline, with REQUIRED fixture paths: no default, no skip and no
/// pass-on-missing. The fresh Dart-produced capture is the independent oracle:
/// the strict decode of the Swift export is compared against it instead of
/// trusting the produced bytes themselves.
const _exportPath = String.fromEnvironment('NATIVE_ACCOUNT_SCHEMA3_EXPORT');
const _sourcePath = String.fromEnvironment('NATIVE_ACCOUNT_SCHEMA3_SOURCE');
const _caseID = 'stored-10-2-owner-2-10';
const _consumedName = 'schema3-export-consumed.json';
const _uuidPattern =
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
const _metadataKeys = {
  'schema', 'sourceSHA', 'workflowSHA', 'transactionID',
  'envelopeSchemaVersion', 'envelopeByteCount', 'envelopeSHA256', 'wireFileName',
};

Map<String, Object?> _map(Object? value) =>
    (value as Map).cast<String, Object?>();

List<Object?> _list(Object? value) => (value as List).cast<Object?>();

Object? _copy(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries) entry.key as String: _copy(entry.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final child in value) _copy(child)];
  }
  return value;
}

Map<String, Object?> _copyMap(Object? value) => _map(_copy(value));

Future<Map<String, Object?>> _metadata() async {
  final metadata = _map(jsonDecode(await File(_exportPath).readAsString()));
  return metadata;
}

File _wireFile(Map<String, Object?> metadata) {
  final wire = File('${File(_exportPath).parent.path}/${metadata['wireFileName']}');
  expect(wire.existsSync(), isTrue, reason: 'Swift producer wire file missing');
  return wire;
}

Future<Map<String, Object?>> _mutableWire() async {
  final metadata = await _metadata();
  final bytes = await _wireFile(metadata).readAsBytes();
  return _copyMap(jsonDecode(utf8.decode(bytes, allowMalformed: false)));
}

Future<Map<String, Object?>> _mutableSourceEnvelope() async {
  final root = _map(jsonDecode(await File(_sourcePath).readAsString()));
  for (final raw in _list(root['cases'])) {
    final item = _map(raw);
    if (item['id'] == _caseID) {
      return _copyMap(item['envelope']);
    }
  }
  throw StateError('fresh Dart capture is missing the $_caseID case');
}

void main() {
  test('consumes the exact Swift-produced schema-3 export bytes', () async {
    expect(_exportPath, isNotEmpty,
        reason: 'NATIVE_ACCOUNT_SCHEMA3_EXPORT is required from the envelope pipeline');
    expect(_sourcePath, isNotEmpty,
        reason: 'NATIVE_ACCOUNT_SCHEMA3_SOURCE is required from the envelope pipeline');
    final metadataFile = File(_exportPath);
    expect(metadataFile.existsSync(), isTrue,
        reason: 'Swift producer metadata is required');
    final metadata = await _metadata();
    expect(metadata.keys.toSet(), _metadataKeys);
    expect(metadata['schema'], 'pili.account.schema3-export.v1');
    expect(RegExp(r'^[0-9a-f]{40}$').hasMatch(metadata['sourceSHA']! as String),
        isTrue);
    final workflowSHA = metadata['workflowSHA'];
    expect(
        workflowSHA == null ||
            RegExp(r'^[0-9a-f]{40}$').hasMatch(workflowSHA as String),
        isTrue);
    expect(RegExp(_uuidPattern).hasMatch(metadata['transactionID']! as String),
        isTrue);
    expect(metadata['envelopeSchemaVersion'], 3);
    final bytes = await _wireFile(metadata).readAsBytes();
    expect(bytes.length, metadata['envelopeByteCount']);
    final digest = sha256.convert(bytes).toString();
    expect(digest, metadata['envelopeSHA256']);
    // Strict decode of the exact bytes; the parsed map is never re-encoded as
    // the oracle.
    final envelope = _map(jsonDecode(utf8.decode(bytes, allowMalformed: false)));
    expect(envelope['schemaVersion'], 3);
    final consumed = File('${metadataFile.parent.path}/$_consumedName');
    await consumed.writeAsString(jsonEncode({
      'schema': 'pili.account.schema3-export.consumed.v1',
      'transactionID': metadata['transactionID'],
      'envelopeSHA256': digest,
      'envelopeByteCount': bytes.length,
    }));
  });

  test('strict schema-3 wire preserves the independent Dart capture projection',
      () async {
    final wireResult = NativeAccountReverseImport.decode(await _mutableWire());
    expect(wireResult.value['schemaVersion'], 3);
    final sourceResult =
        NativeAccountReverseImport.decode(await _mutableSourceEnvelope());
    expect(sourceResult.value['schemaVersion'], 2);
    final wireRecords = _list(wireResult.value['records']);
    final sourceRecords = _list(sourceResult.value['records']);
    expect(wireRecords.length, sourceRecords.length);
    for (var index = 0; index < sourceRecords.length; index++) {
      final wireRecord =
          Map<String, Object?>.from(_map(wireRecords[index]))..remove('durableIdentity');
      final sourceRecord = _map(sourceRecords[index]);
      expect(sourceRecord.containsKey('durableIdentity'), isFalse,
          reason: 'legacy schema-2 capture record $index');
      expect(wireRecord, equals(sourceRecord), reason: 'record $index');
    }
    final loginGenerations = [
      for (final record in sourceRecords.skip(1))
        _map(record)['generation']! as int,
    ];
    expect(_map(wireResult.value)['generationHighWater'],
        loginGenerations.reduce((a, b) => a > b ? a : b));
    for (final key in const [
      'scope', 'identityScope', 'revision', 'durableIdentityConfigured',
      'durabilityVerified', 'authoritySwitchAllowed', 'nativeWritesAllowed',
      'storedOrder', 'ownerOrder', 'selectionPurposes', 'selections', 'history',
    ]) {
      expect(_map(wireResult.value)[key], equals(_map(sourceResult.value)[key]),
          reason: key);
    }
  });

  test('login durable identities are canonical unique lowercase UUID labels',
      () async {
    final result = NativeAccountReverseImport.decode(await _mutableWire());
    final identities = result.recordDurableIdentities;
    expect(identities.length, _list(result.value['records']).length);
    expect(identities.first, isNull);
    final canonical = RegExp(_uuidPattern);
    for (final identity in identities.skip(1)) {
      expect(identity, isNotNull);
      expect(canonical.hasMatch(identity!), isTrue);
    }
    expect(identities.skip(1).toSet().length, identities.length - 1);
  });

  test('rejects a schema-3 wire whose login identity is missing', () async {
    final wire = await _mutableWire();
    final records = _list(wire['records']);
    _map(records[1]).remove('durableIdentity');
    expect(() => NativeAccountReverseImport.decode(wire),
        throwsA(isA<NativeAccountReverseImportException>()));
  });

  test('rejects mutated or extended schema-3 projections', () async {
    final duplicate = await _mutableWire();
    final duplicateRecords = _list(duplicate['records']);
    _map(duplicateRecords[1])['generation'] =
        _map(duplicateRecords[2])['generation'];
    expect(() => NativeAccountReverseImport.decode(duplicate),
        throwsA(isA<NativeAccountReverseImportException>()));
    final extended = await _mutableWire();
    extended['unexpected'] = true;
    expect(() => NativeAccountReverseImport.decode(extended),
        throwsA(isA<NativeAccountReverseImportException>()));
  });

  test('rejects a schema-2 capture record carrying a durable identity',
      () async {
    final source = await _mutableSourceEnvelope();
    final records = _list(source['records']);
    _map(records[1])['durableIdentity'] = <int>[
      for (final unit in '00000000-0000-0000-0000-000000000000'.codeUnits) unit,
    ];
    expect(() => NativeAccountReverseImport.decode(source),
        throwsA(isA<NativeAccountReverseImportException>()));
  });
}
