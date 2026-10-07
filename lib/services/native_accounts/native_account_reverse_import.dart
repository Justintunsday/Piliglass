import 'dart:io' show SameSite;

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:cookie_jar/cookie_jar.dart';

/// Reverse-import boundary for a durable Native schema 2 envelope. It is a
/// compatibility reader, not the Native strict codec: it validates the known
/// shape and limits, reconstructs owned jar maps with full attributes and only
/// then registers accounts through the normal owner path. Missing or malformed
/// input throws before any live account is touched.
final class NativeAccountReverseImportException implements Exception {
  const NativeAccountReverseImportException(this.code);

  final String code;
}

final class NativeAccountReverseImportResult {
  NativeAccountReverseImportResult._({
    required this.accounts,
    required this.accountKeys,
    required this.selectedAccounts,
    required this.historyAccount,
    required this.persistedPurposes,
  });

  /// Login accounts in durable stored order (envelope ordinals 1...N).
  final List<LoginAccount> accounts;
  final List<String> accountKeys;
  final List<Account> selectedAccounts;
  final Account historyAccount;
  final List<Set<AccountType>> persistedPurposes;
}

abstract final class NativeAccountReverseImport {
  static const _maxRecords = 256;
  static const _maxBuckets = 8192;
  static const _maxCookies = 16384;
  static const _maxKeyUnits = 4096;
  static const _maxNameUnits = 1024;
  static const _maxValueUnits = 65536;

  /// Pure decode. Does not call Accounts, Hive or the network.
  static NativeAccountReverseImportResult decode(Map<String, Object?> envelope) {
    _expect(envelope['schemaVersion'] == 2, 'unsupportedSchema');
    _expect(envelope['scope'] == 'coherentLiveMemoryShadow', 'invalidEnvelope');
    _expect(envelope['identityScope'] == 'captureLocal', 'invalidEnvelope');
    for (final flag in [
      'durableIdentityConfigured',
      'durabilityVerified',
      'authoritySwitchAllowed',
      'nativeWritesAllowed',
    ]) {
      _expect(envelope[flag] == false, 'invalidEnvelope');
    }
    _expect(envelope['revision'] is int && (envelope['revision']! as int) >= 0,
      'invalidEnvelope');
    final records = _list(envelope['records'], 'invalidEnvelope');
    _expect(records.isNotEmpty && records.length <= _maxRecords, 'invalidEnvelope');
    final selections = _list(envelope['selections'], 'invalidEnvelope');
    _expect(selections.length == 4, 'invalidEnvelope');
    final selectedOrdinals = [
      for (final value in selections) _ordinal(value),
    ];
    _expect(selectedOrdinals.every((value) => value < records.length), 'invalidEnvelope');
    final history = _ordinal(envelope['history']);
    _expect(history < records.length, 'invalidEnvelope');
    _expect(_standardPurposes(envelope['selectionPurposes']) != null, 'invalidEnvelope');

    var bucketCount = 0;
    var cookieCount = 0;
    final accounts = <LoginAccount>[];
    final keys = <String>[];
    final persisted = <Set<AccountType>>[];
    for (var ordinal = 0; ordinal < records.length; ordinal++) {
      final record = _map(records[ordinal], 'invalidEnvelope');
      _expect(record['record'] == ordinal, 'invalidEnvelope');
      _expect(record['generation'] is int && (record['generation']! as int) > 0,
        'invalidEnvelope');
      _expect(record['isLogin'] is bool, 'invalidEnvelope');
      final isLogin = record['isLogin']! as bool;
      final recordPurposes = _recordPurposes(record['persistedPurposes']);
      final blueprint = _blueprint(_map(record['jar'], 'invalidEnvelope'),
        onBucket: () {
          _expect(++bucketCount <= _maxBuckets, 'resourceLimit');
        },
        onCookie: () {
          _expect(++cookieCount <= _maxCookies, 'resourceLimit');
        });
      if (ordinal == 0) {
        _expect(!isLogin && record['mid'] == 0 && record['storageKeyUnits'] == null,
          'invalidEnvelope');
        _expect(record['accessKeyUnits'] == null && record['refreshTokenUnits'] == null,
          'invalidEnvelope');
        continue;
      }
      _expect(isLogin, 'invalidEnvelope');
      final key = _units(record['storageKeyUnits'], _maxKeyUnits);
      _expect(!keys.contains(key), 'invalidEnvelope');
      final jar = blueprint.materialize();
      // The captured raw key is authoritative. The constructor caches
      // LoginAccount.storageKey from this value; the jar itself is restored
      // byte-faithful afterwards, including a previously mutated DedeUserID.
      final originalIdentity = _readIdentityValue(jar);
      _writeIdentityValue(jar, key);
      final account = LoginAccount(
        jar,
        _optionalUnits(record['accessKeyUnits'], _maxValueUnits),
        _optionalUnits(record['refreshTokenUnits'], _maxValueUnits),
        recordPurposes,
      )..activated = record['activated'] == true;
      final capturedKey = account.storageKey;
      _expect(capturedKey == key, 'invalidCapturedIdentity');
      blueprint.restore(jar);
      if (originalIdentity != key) _writeIdentityValue(jar, originalIdentity);
      accounts.add(account);
      keys.add(key);
      persisted.add(recordPurposes);
    }
    final selected = [
      for (final ordinal in selectedOrdinals)
        ordinal == 0 ? AnonymousAccount() : accounts[ordinal - 1],
    ];
    return NativeAccountReverseImportResult._(
      accounts: List.unmodifiable(accounts),
      accountKeys: List.unmodifiable(keys),
      selectedAccounts: List.unmodifiable(selected),
      historyAccount: history == 0 ? AnonymousAccount() : accounts[history - 1],
      persistedPurposes: List.unmodifiable(persisted),
    );
  }

  static _JarBlueprint _blueprint(
    Map<String, Object?> json, {
    required void Function() onBucket,
    required void Function() onCookie,
  }) {
    _expect(json['schemaVersion'] == 2, 'invalidJar');
    _expect(json['ignoreExpires'] is bool, 'invalidJar');
    return _JarBlueprint._(
      json['ignoreExpires']! as bool,
      _bucketGroup(json['domainBuckets'], onBucket, onCookie),
      _bucketGroup(json['hostBuckets'], onBucket, onCookie),
    );
  }

  static Map<String, Map<String, Map<String, SerializableCookie>>> _bucketGroup(
    Object? value,
    void Function() onBucket,
    void Function() onCookie,
  ) {
    final result = <String, Map<String, Map<String, SerializableCookie>>>{};
    for (final rawBucket in _list(value, 'invalidJar')) {
      onBucket();
      final bucket = _map(rawBucket, 'invalidJar');
      final key = _units(bucket['keyUnits'], _maxKeyUnits);
      _expect(!result.containsKey(key), 'invalidJar');
      final paths = <String, Map<String, SerializableCookie>>{};
      for (final rawPath in _list(bucket['paths'], 'invalidJar')) {
        onBucket();
        final path = _map(rawPath, 'invalidJar');
        final pathKey = _units(path['keyUnits'], _maxKeyUnits);
        _expect(!paths.containsKey(pathKey), 'invalidJar');
        final cookies = <String, SerializableCookie>{};
        for (final rawCookie in _list(path['cookies'], 'invalidJar')) {
          onCookie();
          final entry = _map(rawCookie, 'invalidJar');
          final mapKey = _units(entry['keyUnits'], _maxKeyUnits);
          _expect(!cookies.containsKey(mapKey), 'invalidJar');
          cookies[mapKey] = _serializable(entry);
        }
        paths[pathKey] = cookies;
      }
      result[key] = paths;
    }
    return result;
  }

  static SerializableCookie _serializable(Map<String, Object?> entry) {
    final name = _units(entry['nameUnits'], _maxNameUnits);
    final value = _units(entry['valueUnits'], _maxValueUnits);
    final expires = entry['expiresMicroseconds'];
    final maxAge = entry['maxAgeSeconds'];
    _expect(maxAge == null || maxAge is int, 'invalidJar');
    final cookie = Cookie(name, value)
      ..domain = _optionalUnits(entry['cookieDomainUnits'], _maxKeyUnits)
      ..path = _optionalUnits(entry['cookiePathUnits'], _maxKeyUnits)
      ..secure = entry['secure'] == true
      ..httpOnly = entry['httpOnly'] == true
      ..sameSite = _sameSite(entry['sameSite']);
    if (expires != null) {
      if (expires is! int) throw const NativeAccountReverseImportException('invalidJar');
      cookie.expires = DateTime.fromMicrosecondsSinceEpoch(expires, isUtc: true);
    }
    if (maxAge != null) cookie.maxAge = maxAge as int;
    final created = entry['createdSeconds'];
    if (created is! int || created < 0) {
      throw const NativeAccountReverseImportException('invalidJar');
    }
    return SerializableCookie(cookie)..createTimeStamp = created;
  }

  static String _readIdentityValue(DefaultCookieJar jar) {
    final stored = jar.domainCookies['bilibili.com']?['/']?['DedeUserID'];
    if (stored == null) {
      throw const NativeAccountReverseImportException('missingCapturedIdentity');
    }
    return stored.cookie.value;
  }

  static void _writeIdentityValue(DefaultCookieJar jar, String value) {
    jar.domainCookies['bilibili.com']!['/']!['DedeUserID']!.cookie.value = value;
  }

  static SameSite? _sameSite(Object? value) {
    _expect(value == null || value is String, 'invalidJar');
    return switch (value) {
      null => null,
      'Strict' => SameSite.strict,
      'Lax' => SameSite.lax,
      'None' => SameSite.none,
      _ => throw const NativeAccountReverseImportException('invalidJar'),
    };
  }

  static List<String>? _standardPurposes(Object? value) {
    final list = value is List ? value : null;
    if (list == null || list.length != AccountType.values.length) return null;
    final names = [for (final item in list) item];
    if (!const ['main', 'heartbeat', 'recommend', 'video'].every(names.contains)) {
      return null;
    }
    return [for (final item in list) item as String];
  }

  static Set<AccountType> _recordPurposes(Object? value) {
    final list = value is List ? value : null;
    if (list == null || list.length > AccountType.values.length) {
      throw const NativeAccountReverseImportException('invalidEnvelope');
    }
    final result = <AccountType>{};
    for (final item in list) {
      _expect(item is String, 'invalidEnvelope');
      final match = AccountType.values.where((type) => type.name == item);
      _expect(match.length == 1 && result.add(match.single), 'invalidEnvelope');
    }
    return result;
  }

  static String _units(Object? value, int maximum) {
    final list = _list(value, 'invalidJar');
    _expect(list.length <= maximum, 'resourceLimit');
    final units = <int>[];
    for (final unit in list) {
      _expect(unit is int && unit >= 0 && unit <= 0xffff, 'invalidJar');
      units.add(unit as int);
    }
    return String.fromCharCodes(units);
  }

  static String? _optionalUnits(Object? value, int maximum) =>
      value == null ? null : _units(value, maximum);

  static int _ordinal(Object? value) {
    _expect(value is int && value >= 0, 'invalidEnvelope');
    return value as int;
  }

  static List<Object?> _list(Object? value, String code) {
    if (value is! List) throw NativeAccountReverseImportException(code);
    return value.cast<Object?>();
  }

  static Map<String, Object?> _map(Object? value, String code) {
    if (value is! Map) throw NativeAccountReverseImportException(code);
    return value.cast<String, Object?>();
  }

  static void _expect(bool condition, String code) {
    if (!condition) throw NativeAccountReverseImportException(code);
  }
}

/// Registers a decoded reverse-import result through the normal owner path and
/// restores the captured effective selections. Callers own writer freeze and
/// the authority transition; this service never switches authority itself.
final class NativeAccountReverseImportService {
  Future<void> apply(NativeAccountReverseImportResult result) async {
    await Accounts.importCredentials({
      for (final account in result.accounts) account.storageKey: account,
    });
    for (var index = 0; index < AccountType.values.length; index++) {
      Accounts.selectTemporarily(AccountType.values[index], result.selectedAccounts[index]);
    }
  }
}

final class _JarBlueprint {
  _JarBlueprint._(this.ignoreExpires, this._domains, this._hosts);

  final bool ignoreExpires;
  final Map<String, Map<String, Map<String, SerializableCookie>>> _domains;
  final Map<String, Map<String, Map<String, SerializableCookie>>> _hosts;

  DefaultCookieJar materialize() {
    final jar = DefaultCookieJar(ignoreExpires: ignoreExpires);
    jar.domainCookies
      ..clear()
      ..addAll(_copy(_domains));
    jar.hostCookies
      ..clear()
      ..addAll(_copy(_hosts));
    return jar;
  }

  /// Restores the exact captured maps after the LoginAccount constructor has
  /// run its buvid side effect, so the durable jar stays byte-faithful.
  void restore(DefaultCookieJar jar) {
    jar.domainCookies
      ..clear()
      ..addAll(_copy(_domains));
    jar.hostCookies
      ..clear()
      ..addAll(_copy(_hosts));
  }

  static Map<String, Map<String, Map<String, SerializableCookie>>> _copy(
    Map<String, Map<String, Map<String, SerializableCookie>>> source,
  ) => {
    for (final bucket in source.entries)
      bucket.key: {
        for (final path in bucket.value.entries) path.key: Map.of(path.value),
      },
  };
}
