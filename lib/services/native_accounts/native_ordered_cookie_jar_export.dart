import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';

enum NativeOrderedCookiePriorPersistence { unknown, legacyHiveReopened }

final class NativeOrderedCookieJarExportException implements Exception {
  const NativeOrderedCookieJarExportException(this.code);

  final String code;
}

/// Copies the current live jar for shadow comparison only. No writer, account
/// identity, bridge command, expiry calculation or request authorization lives
/// here. The old Hive adapter's historical losses cannot be reconstructed.
abstract final class NativeOrderedCookieJarExporter {
  static const maxWireBytes = 16 * 1024 * 1024;
  static const maxUTF16Units = 2 * 1024 * 1024;
  static const maxBuckets = 8192;
  static const maxCookies = 16384;
  static const maxKeyUnits = 4096;
  static const maxNameUnits = 1024;
  static const maxValueUnits = 65536;

  /// Synchronous copying retains each Map's iteration order, including empty
  /// buckets. All Cookie strings and keys are owned UTF-16 arrays; malformed
  /// surrogate pairs are preserved rather than normalized or replaced.
  static Map<String, Object?> export(
    DefaultCookieJar jar, {
    NativeOrderedCookiePriorPersistence priorPersistence =
        NativeOrderedCookiePriorPersistence.unknown,
  }) {
    final budget = _ExportBudget();
    final result = <String, Object?>{
      'schemaVersion': 2,
      'ignoreExpires': jar.ignoreExpires,
      'provenance': <String, Object?>{
        'capture': 'live',
        'priorPersistence': priorPersistence.name,
        // This exporter has no provenance registry for earlier Hive writes.
        // Even a complete live copy cannot prove its pre-Hive history.
        'legacyHiveAttributesIncomplete': true,
        'currentBucketOrderComplete': true,
      },
      'domainBuckets': _buckets(jar.domainCookies, budget),
      'hostBuckets': _buckets(jar.hostCookies, budget),
    };
    if (utf8.encode(jsonEncode(result)).length > maxWireBytes) {
      throw const NativeOrderedCookieJarExportException('wireCapacityExceeded');
    }
    return result;
  }

  static List<Map<String, Object?>> _buckets(
    Map<String, Map<String, Map<String, SerializableCookie>>> source,
    _ExportBudget budget,
  ) => [
    for (final domain in source.entries)
      _bucket(domain.key, domain.value, budget),
  ];

  static Map<String, Object?> _bucket(
    String key,
    Map<String, Map<String, SerializableCookie>> paths,
    _ExportBudget budget,
  ) {
    budget.addBucket();
    return <String, Object?>{
      'keyUnits': budget.units(key, maxKeyUnits),
      'paths': [
        for (final path in paths.entries)
          _path(path.key, path.value, budget),
      ],
    };
  }

  static Map<String, Object?> _path(
    String key,
    Map<String, SerializableCookie> cookies,
    _ExportBudget budget,
  ) {
    budget.addBucket();
    return <String, Object?>{
      'keyUnits': budget.units(key, maxKeyUnits),
      'cookies': [
        for (final entry in cookies.entries)
          _cookie(entry.key, entry.value, budget),
      ],
    };
  }

  static Map<String, Object?> _cookie(
    String key,
    SerializableCookie stored,
    _ExportBudget budget,
  ) {
    budget.addCookie();
    if (stored.createTimeStamp < 0) {
      throw const NativeOrderedCookieJarExportException('invalidCreationTime');
    }
    final cookie = stored.cookie;
    return <String, Object?>{
      // The public jar maps can have a key different from Cookie.name.
      // Keep both instead of using values iteration to discard that key.
      'keyUnits': budget.units(key, maxKeyUnits),
      'nameUnits': budget.units(cookie.name, maxNameUnits),
      'valueUnits': budget.units(cookie.value, maxValueUnits),
      'cookieDomainUnits': budget.optionalUnits(cookie.domain, maxKeyUnits),
      'cookiePathUnits': budget.optionalUnits(cookie.path, maxKeyUnits),
      'secure': cookie.secure,
      'httpOnly': cookie.httpOnly,
      'sameSite': cookie.sameSite?.name,
      'expiresMicroseconds': cookie.expires?.microsecondsSinceEpoch,
      'maxAgeSeconds': cookie.maxAge,
      'createdSeconds': stored.createTimeStamp,
    };
  }
}

final class _ExportBudget {
  int _units = 0;
  int _buckets = 0;
  int _cookies = 0;

  List<int>? optionalUnits(String? value, int limit) =>
      value == null ? null : units(value, limit);

  List<int> units(String value, int limit) {
    if (value.length > limit) {
      throw const NativeOrderedCookieJarExportException('stringCapacityExceeded');
    }
    _units += value.length;
    if (_units > NativeOrderedCookieJarExporter.maxUTF16Units) {
      throw const NativeOrderedCookieJarExportException('unitCapacityExceeded');
    }
    return List<int>.of(value.codeUnits);
  }

  void addBucket() {
    if (++_buckets > NativeOrderedCookieJarExporter.maxBuckets) {
      throw const NativeOrderedCookieJarExportException('bucketCapacityExceeded');
    }
  }

  void addCookie() {
    if (++_cookies > NativeOrderedCookieJarExporter.maxCookies) {
      throw const NativeOrderedCookieJarExportException('cookieCapacityExceeded');
    }
  }
}
