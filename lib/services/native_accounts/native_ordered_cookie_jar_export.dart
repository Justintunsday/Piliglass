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
    NativeOrderedCookieExportBudget? cumulativeBudget,
  }) {
    final budget = (cumulativeBudget ?? NativeOrderedCookieExportBudget())
      ..reserveNodes(10);
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
    verifyWireCapacity(result);
    return result;
  }

  /// Counts bounded UTF8 chunks of an already bounded owned shadow tree.
  /// This is not a parser or a validation entry point for untrusted JSON.
  static void verifyWireCapacity(Object? value) {
    JsonUtf8Encoder().startChunkedConversion(_WireCapacitySink())
      ..add(value)
      ..close();
  }

  static List<Map<String, Object?>> _buckets(
    Map<String, Map<String, Map<String, SerializableCookie>>> source,
    NativeOrderedCookieExportBudget budget,
  ) => [
    for (final domain in source.entries)
      _bucket(domain.key, domain.value, budget),
  ];

  static Map<String, Object?> _bucket(
    String key,
    Map<String, Map<String, SerializableCookie>> paths,
    NativeOrderedCookieExportBudget budget,
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
    NativeOrderedCookieExportBudget budget,
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
    NativeOrderedCookieExportBudget budget,
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

/// Shared preallocation ledger for one complete shadow candidate. Jar output
/// retains its fixed shape; nodes count JSON values, including each UTF16 unit.
final class NativeOrderedCookieExportBudget {
  int _nodes = 0;
  int _units = 0;
  int _buckets = 0;
  int _cookies = 0;

  void reserveNodes(int count) {
    if (count < 0 || (_nodes += count) > 3 * 1024 * 1024) {
      throw const NativeOrderedCookieJarExportException('nodeCapacityExceeded');
    }
  }

  void reserveUnits(int count) {
    if (count < 0 || (_units += count) > NativeOrderedCookieJarExporter.maxUTF16Units) {
      throw const NativeOrderedCookieJarExportException('unitCapacityExceeded');
    }
  }

  List<int>? optionalUnits(String? value, int limit) {
    if (value == null) {
      reserveNodes(1);
      return null;
    }
    return units(value, limit);
  }

  List<int> units(String value, int limit) {
    if (value.length > limit) {
      throw const NativeOrderedCookieJarExportException('stringCapacityExceeded');
    }
    reserveUnits(value.length);
    reserveNodes(1 + value.length);
    return List<int>.of(value.codeUnits);
  }

  void addBucket() {
    reserveNodes(2);
    if (++_buckets > NativeOrderedCookieJarExporter.maxBuckets) {
      throw const NativeOrderedCookieJarExportException('bucketCapacityExceeded');
    }
  }

  void addCookie() {
    reserveNodes(7);
    if (++_cookies > NativeOrderedCookieJarExporter.maxCookies) {
      throw const NativeOrderedCookieJarExportException('cookieCapacityExceeded');
    }
  }
}

final class _WireCapacitySink implements Sink<List<int>> {
  int _bytes = 0;

  @override
  void add(List<int> data) {
    if ((_bytes += data.length) > NativeOrderedCookieJarExporter.maxWireBytes) {
      throw const NativeOrderedCookieJarExportException('wireCapacityExceeded');
    }
  }

  @override
  void close() {}
}
