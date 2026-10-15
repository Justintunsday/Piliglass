import 'dart:io' show SameSite;

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/account_install_persistence_port.dart';
import 'package:PiliPlus/services/native_accounts/native_ordered_cookie_jar_export.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:cookie_jar/cookie_jar.dart';

final class NativeAccountReverseImportException implements Exception {
  const NativeAccountReverseImportException(this.code);
  final String code;
}

/// Owned, deeply immutable data only. No Account, jar or live singleton escapes.
final class NativeAccountReverseImportResult {
  const NativeAccountReverseImportResult._(this.value, this.accountKeys, this.recordDurableIdentities);
  final Map<String, Object?> value;
  final List<String> accountKeys;
  /// Order-aligned with `records`: the validated canonical lowercase UUID text
  /// of each schema-3 login record's durable identity, null for the anonymous
  /// record and for schema-2 captures. Correlation labels only — never request
  /// authorization — and never mixed with the bridge tracker tokens.
  final List<String?> recordDurableIdentities;
}

abstract final class NativeAccountReverseImport {
  /// Validates the entire candidate before allocating the owned blueprint.
  /// Never constructs LoginAccount/AnonymousAccount or reads Pref/Hive.
  static NativeAccountReverseImportResult decode(Map<String, Object?> envelope) {
    try {
      final reader = _EnvelopeReader(envelope)..validate();
      NativeOrderedCookieJarExporter.verifyWireCapacity(envelope);
      return NativeAccountReverseImportResult._(
        _freeze(envelope) as Map<String, Object?>,
        List.unmodifiable(reader.keys),
        List.unmodifiable(reader.durableIdentities),
      );
    } on NativeOrderedCookieJarExportException {
      throw const NativeAccountReverseImportException('resourceLimit');
    }
  }
}

/// Empty-target-only, in-memory compatibility staging. NOT durable rollback:
/// Hive's legacy adapters still lose attributes on restart. Callers own the
/// authority transition/freeze. A nonempty target is rejected, never cleared.
final class NativeAccountReverseImportService {
  const NativeAccountReverseImportService({
    this.persistencePort = accountInstallPersistencePort,
  });

  final AccountInstallPersistencePort persistencePort;

  Future<void> apply(NativeAccountReverseImportResult result) async {
    // Check before creating even detached Account objects.
    Accounts.requireEmptyCapturedRestoreTarget();
    final records = _list(result.value['records']);
    final accounts = <LoginAccount>[];
    for (final raw in records.skip(1)) {
      final record = _map(raw);
      accounts.add(LoginAccount.restoreCaptured(
        cookieJar: _materialize(_map(record['jar'])),
        storageKey: _string(record['storageKeyUnits']),
        mid: record['mid']! as int,
        accessKey: _optionalString(record['accessKeyUnits']),
        refresh: _optionalString(record['refreshTokenUnits']),
        purposes: _purposes(record['persistedPurposes']),
        activated: record['activated']! as bool,
      ));
    }
    final anonymous = _map(records.first);
    await Accounts.restoreEmptyCaptured(
      accounts: accounts,
      ownerOrdinals: [
        for (final entry in _list(result.value['ownerOrder']))
          _map(entry)['record']! as int,
      ],
      anonymousJar: _materialize(_map(anonymous['jar'])),
      anonymousPurposes: _purposes(anonymous['persistedPurposes']),
      anonymousActivated: anonymous['activated']! as bool,
      selections: _list(result.value['selections']).cast<int>(),
      persistencePort: persistencePort,
    );
  }
}

final class _EnvelopeReader {
  _EnvelopeReader(this.value);
  final Map<String, Object?> value;
  final budget = NativeOrderedCookieExportBudget();
  final keys = <String>[];
  final durableIdentities = <String?>[];
  final identities = <String>{};
  static const purposes = ['main', 'heartbeat', 'recommend', 'video'];
  static const shadowFields = [
    'schemaVersion', 'scope', 'identityScope', 'revision',
    'durableIdentityConfigured', 'durabilityVerified',
    'authoritySwitchAllowed', 'nativeWritesAllowed', 'records',
    'storedOrder', 'ownerOrder', 'selectionPurposes', 'selections', 'history',
  ];
  static const modernShadowFields = [...shadowFields, 'generationHighWater'];
  static const recordFields = [
    'record', 'generation', 'storageKeyUnits', 'mid',
    'isLogin', 'accessKeyUnits', 'refreshTokenUnits', 'persistedPurposes',
    'activated', 'jar',
  ];
  static const modernRecordFields = [...recordFields, 'durableIdentity'];

  void validate() {
    final version = _integer(value['schemaVersion']);
    _expect(version == 2 || version == 3, 'unsupportedSchema');
    final schemaThree = version == 3;
    // Schema 3 may carry the monotonic generation high-water at the top level
    // and a durable identity per login record. Schema 2 keeps the exact legacy
    // key sets, so any extra field (including a null `durableIdentity`) fails.
    final modernShadow = schemaThree && _hasShape(value, modernShadowFields);
    _shape(value, modernShadow ? modernShadowFields : shadowFields);
    _expect(value['scope'] == 'coherentLiveMemoryShadow');
    _expect(value['identityScope'] == 'captureLocal');
    for (final flag in const ['durableIdentityConfigured', 'durabilityVerified',
      'authoritySwitchAllowed', 'nativeWritesAllowed']) {
      _expect(!_boolean(value[flag]));
    }
    _expect(_integer(value['revision']) >= 0);
    final rawHighWater = modernShadow ? value['generationHighWater'] : null;
    final highWater = rawHighWater == null ? null : _integer(rawHighWater);
    if (highWater != null) _expect(highWater >= 0);
    final records = _list(value['records']);
    _expect(records.isNotEmpty);
    _expect(records.length <= 256, 'resourceLimit');
    final selections = _list(value['selections']);
    _expect(selections.length == 4);
    _expect(_sameList(_list(value['selectionPurposes']), purposes));
    budget.reserveUnits(2048 + 512 * records.length);
    _preflight(value, 0);
    final generations = <int>{};
    final uniqueKeys = <String>{};
    var maxGeneration = 0;
    for (var index = 0; index < records.length; index++) {
      final record = _map(records[index]);
      final modernRecord = schemaThree && _hasShape(record, modernRecordFields);
      _shape(record, modernRecord ? modernRecordFields : recordFields);
      _expect(_integer(record['record']) == index);
      final generation = _integer(record['generation']);
      _expect(generation > 0 && generations.add(generation));
      final mid = _integer(record['mid']);
      _boolean(record['activated']);
      _purposes(record['persistedPurposes']);
      final identity = modernRecord ? record['durableIdentity'] : null;
      if (index == 0) {
        _expect(!_boolean(record['isLogin']) && mid == 0);
        _expect(record['storageKeyUnits'] == null && record['accessKeyUnits'] == null &&
          record['refreshTokenUnits'] == null && identity == null);
        durableIdentities.add(null);
      } else {
        _expect(_boolean(record['isLogin']));
        final key = _units(record['storageKeyUnits'], 4096);
        _expect(uniqueKeys.add(key));
        keys.add(key);
        _optionalUnits(record['accessKeyUnits'], 65536);
        _optionalUnits(record['refreshTokenUnits'], 65536);
        if (schemaThree) {
          final canonical = _canonicalDurableIdentity(identity);
          _expect(identities.add(canonical));
          budget.reserveUnits(36);
          durableIdentities.add(canonical);
        } else {
          durableIdentities.add(null);
        }
        if (generation > maxGeneration) maxGeneration = generation;
      }
      _jar(_map(record['jar']));
    }
    if (highWater != null) _expect(highWater >= maxGeneration);
    final stored = _list(value['storedOrder']);
    final owners = _list(value['ownerOrder']);
    _expect(stored.length == keys.length && owners.length == keys.length);
    final ownerIds = <int>{};
    for (var index = 0; index < stored.length; index++) {
      final entry = _map(stored[index]);
      _shape(entry, const ['keyUnits', 'record']);
      _expect(_integer(entry['record']) == index + 1);
      _expect(_units(entry['keyUnits'], 4096) == keys[index]);
      // Actual Hive Box string keys are sorted with Dart UTF16 comparison.
      if (index > 0) _expect(keys[index - 1].compareTo(keys[index]) < 0);
    }
    for (final raw in owners) {
      final entry = _map(raw);
      _shape(entry, const ['keyUnits', 'record']);
      final ordinal = _integer(entry['record']);
      _expect(ordinal > 0 && ordinal < records.length && ownerIds.add(ordinal));
      _expect(_units(entry['keyUnits'], 4096) == keys[ordinal - 1]);
    }
    for (final raw in selections) {
      final ordinal = _integer(raw);
      _expect(ordinal >= 0 && ordinal < records.length);
    }
    final heartbeat = selections[1]! as int;
    _expect(_integer(value['history']) == (heartbeat == 0 ? selections[0] : heartbeat));
  }

  /// All resource accounting happens before strings/Cookies/owned DTO copies.
  /// Reuses the exporter ledger and bounded UTF8 sink for the same ceilings.
  void _preflight(Object? node, int depth) {
    _expect(depth <= 32, 'resourceLimit');
    budget.reserveNodes(1);
    if (node is Map) {
      for (final entry in node.entries) {
        _expect(entry.key is String);
        if ((entry.key as String).endsWith('Units') && entry.value is List) {
          budget.reserveUnits((entry.value as List).length);
        }
        _preflight(entry.value, depth + 1);
      }
    } else if (node is List) {
      for (final child in node) {
        _preflight(child, depth + 1);
      }
    } else {
      _expect(node == null || node is String || node is bool || node is int);
    }
  }

  void _jar(Map<String, Object?> jar) {
    _shape(jar, const ['schemaVersion', 'ignoreExpires', 'provenance', 'domainBuckets', 'hostBuckets']);
    _expect(_integer(jar['schemaVersion']) == 2);
    _boolean(jar['ignoreExpires']);
    final provenance = _map(jar['provenance']);
    _shape(provenance, const ['capture', 'priorPersistence',
      'legacyHiveAttributesIncomplete', 'currentBucketOrderComplete']);
    _expect(provenance['capture'] == 'live');
    _expect(provenance['priorPersistence'] == 'unknown' ||
      provenance['priorPersistence'] == 'legacyHiveReopened');
    _expect(_boolean(provenance['legacyHiveAttributesIncomplete']));
    _expect(_boolean(provenance['currentBucketOrderComplete']));
    for (final group in ['domainBuckets', 'hostBuckets']) {
      final bucketKeys = <String>{};
      for (final raw in _list(jar[group])) {
        budget.addBucket();
        final bucket = _map(raw);
        _shape(bucket, const ['keyUnits', 'paths']);
        _expect(bucketKeys.add(_units(bucket['keyUnits'], 4096)));
        final pathKeys = <String>{};
        for (final rawPath in _list(bucket['paths'])) {
          budget.addBucket();
          final path = _map(rawPath);
          _shape(path, const ['keyUnits', 'cookies']);
          _expect(pathKeys.add(_units(path['keyUnits'], 4096)));
          final cookieKeys = <String>{};
          for (final rawCookie in _list(path['cookies'])) {
            budget.addCookie();
            final cookie = _map(rawCookie);
            _shape(cookie, const ['keyUnits', 'nameUnits', 'valueUnits', 'cookieDomainUnits',
              'cookiePathUnits', 'secure', 'httpOnly', 'sameSite',
              'expiresMicroseconds', 'maxAgeSeconds', 'createdSeconds']);
            _expect(cookieKeys.add(_units(cookie['keyUnits'], 4096)));
            _units(cookie['nameUnits'], 1024);
            _units(cookie['valueUnits'], 65536);
            _optionalUnits(cookie['cookieDomainUnits'], 4096);
            _optionalUnits(cookie['cookiePathUnits'], 4096);
            _boolean(cookie['secure']);
            _boolean(cookie['httpOnly']);
            _expect(cookie['sameSite'] == null ||
              const ['Strict', 'Lax', 'None'].contains(cookie['sameSite']));
            final expires = cookie['expiresMicroseconds'];
            if (expires != null) {
              final instant = _integer(expires);
              _expect(instant >= -8640000000000000000 && instant <= 8640000000000000000);
            }
            if (cookie['maxAgeSeconds'] != null) _integer(cookie['maxAgeSeconds']);
            _expect(_integer(cookie['createdSeconds']) >= 0);
          }
        }
      }
    }
  }
}

void _expect(bool condition, [String code = 'invalidEnvelope']) {
  if (!condition) throw NativeAccountReverseImportException(code);
}
int _integer(Object? value) {
  _expect(value is int);
  return value! as int;
}
bool _boolean(Object? value) {
  _expect(value is bool);
  return value! as bool;
}
List<Object?> _list(Object? value) {
  _expect(value is List);
  return (value! as List).cast<Object?>();
}
Map<String, Object?> _map(Object? value) {
  _expect(value is Map && value.keys.every((key) => key is String));
  return (value! as Map).cast<String, Object?>();
}
bool _hasShape(Map<String, Object?> value, List<String> fields) =>
    value.length == fields.length && fields.every(value.containsKey);
void _shape(Map<String, Object?> value, List<String> fields) =>
    _expect(_hasShape(value, fields));
/// Canonical lowercase UUID text: exactly 36 UTF-16 units, hyphens at
/// 8/13/18/23 and lowercase hex elsewhere. Correlation label only.
String _canonicalDurableIdentity(Object? raw) {
  final units = _list(raw);
  _expect(units.length == 36);
  for (var offset = 0; offset < units.length; offset++) {
    final unit = units[offset];
    _expect(unit is int && unit >= 0 && unit <= 0xffff);
    final code = unit as int;
    if (offset == 8 || offset == 13 || offset == 18 || offset == 23) {
      _expect(code == 0x2D);
    } else {
      _expect((code >= 0x30 && code <= 0x39) || (code >= 0x61 && code <= 0x66));
    }
  }
  return String.fromCharCodes(units.cast<int>());
}
bool _sameList(List<Object?> a, List<Object?> b) => a.length == b.length &&
    Iterable<int>.generate(a.length).every((index) => a[index] == b[index]);
String _units(Object? raw, int maximum) {
  final units = _list(raw);
  _expect(units.length <= maximum, 'resourceLimit');
  _expect(units.every((unit) => unit is int && unit >= 0 && unit <= 0xffff));
  return String.fromCharCodes(units.cast<int>());
}
String? _optionalUnits(Object? raw, int maximum) => raw == null ? null : _units(raw, maximum);
String _string(Object? raw) => String.fromCharCodes(_list(raw).cast<int>());
String? _optionalString(Object? raw) => raw == null ? null : _string(raw);
Set<AccountType> _purposes(Object? raw) {
  final values = _list(raw);
  _expect(values.length <= 4);
  final result = <AccountType>{};
  for (final name in values) {
    _expect(name is String && _EnvelopeReader.purposes.contains(name));
    _expect(result.add(AccountType.values.firstWhere((purpose) => purpose.name == name)));
  }
  return result;
}
Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries) entry.key as String: _freeze(entry.value),
    });
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}
DefaultCookieJar _materialize(Map<String, Object?> raw) {
  final jar = DefaultCookieJar(ignoreExpires: raw['ignoreExpires']! as bool);
  for (final group in ['domainBuckets', 'hostBuckets']) {
    final target = group == 'domainBuckets' ? jar.domainCookies : jar.hostCookies;
    for (final rawBucket in _list(raw[group])) {
      final bucket = _map(rawBucket);
      final paths = <String, Map<String, SerializableCookie>>{};
      for (final rawPath in _list(bucket['paths'])) {
        final path = _map(rawPath);
        paths[_string(path['keyUnits'])] = {
          for (final rawCookie in _list(path['cookies']))
            _string(_map(rawCookie)['keyUnits']): _cookie(_map(rawCookie)),
        };
      }
      target[_string(bucket['keyUnits'])] = paths;
    }
  }
  return jar;
}
SerializableCookie _cookie(Map<String, Object?> raw) {
  final cookie = Cookie(_string(raw['nameUnits']), _string(raw['valueUnits']))
    ..domain = _optionalString(raw['cookieDomainUnits'])
    ..path = _optionalString(raw['cookiePathUnits'])
    ..secure = raw['secure']! as bool
    ..httpOnly = raw['httpOnly']! as bool
    ..sameSite = switch (raw['sameSite']) {
      'Strict' => SameSite.strict,
      'Lax' => SameSite.lax,
      'None' => SameSite.none,
      _ => null,
    };
  if (raw['expiresMicroseconds'] != null) {
    cookie.expires = DateTime.fromMicrosecondsSinceEpoch(raw['expiresMicroseconds']! as int, isUtc: true);
  }
  if (raw['maxAgeSeconds'] != null) cookie.maxAge = raw['maxAgeSeconds']! as int;
  return SerializableCookie(cookie)..createTimeStamp = raw['createdSeconds']! as int;
}
