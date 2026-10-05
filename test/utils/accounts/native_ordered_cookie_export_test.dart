import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/native_accounts/native_ordered_cookie_jar_export.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/accounts/account_manager/response_cookie_headers.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'account_test_storage.dart';

Map<String, Object?> _capture(DefaultCookieJar jar) =>
    NativeOrderedCookieJarExporter.export(jar);

Map<String, Object?> _entry(Map<String, Object?> archive) {
  final buckets = archive['domainBuckets']! as List<Map<String, Object?>>;
  final paths = buckets.single['paths']! as List<Map<String, Object?>>;
  final entries = paths.single['cookies']! as List<Map<String, Object?>>;
  return entries.single;
}

DefaultCookieJar _single(Cookie cookie, {String key = 'map-key'}) =>
    DefaultCookieJar(ignoreExpires: true)
      ..domainCookies['domain-key'] = {
        'path-key': {key: SerializableCookie(cookie)},
      };

Matcher _exportFailure(String code) => throwsA(
  isA<NativeOrderedCookieJarExportException>().having(
    (error) => error.code,
    'code',
    code,
  ),
);

void main() {
  late AccountTestStorage storage;
  final cases = <Map<String, Object?>>[];
  final limits = <Map<String, Object?>>[];
  final directory = Directory('build/native-ordered-cookie-check');

  void record(
    String id,
    DefaultCookieJar jar, {
    String scope = 'representationOnly',
    String creationPolicy = 'actualSerializableCookie',
  }) {
    final started = DateTime.now().microsecondsSinceEpoch;
    final archive = _capture(jar);
    final finished = DateTime.now().microsecondsSinceEpoch;
    cases.add({
      'id': id,
      'compatibilityScope': scope,
      'creationPolicy': creationPolicy,
      'captureStartedMicroseconds': started,
      'captureFinishedMicroseconds': finished,
      'jar': archive,
    });
  }

  setUpAll(() async {
    storage = await AccountTestStorage.open();
    await directory.create(recursive: true);
  });
  tearDownAll(() async {
    await File('${directory.path}/exporter.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'runtimeCutover': false,
        'source': 'actual CookieJar 4.0.9 / production exporter / Hive type8',
        'clockPolicy': {
          'kind': 'actualDartDateTimeNow',
          'injectedClock': false,
          'seededCreationCases': 'explicitly marked representation bounds only',
          'exactBoundaryProof': false,
        },
        'cases': cases,
        'limitChecks': limits,
      }),
    );
    await storage.close();
  });

  test('empty maps and live insertion order are copied without jar mutation', () {
    final jar = DefaultCookieJar();
    record('empty-jar', jar, scope: 'asciiSmallHeader');
    jar
      ..domainCookies[''] = {}
      ..domainCookies['first-domain'] = {'': {}, '/empty': {}}
      ..domainCookies['last-domain'] = {}
      ..hostCookies[''] = {'': {}}
      ..hostCookies['host-no-paths'] = {};
    record('empty-domain-host-path-name-maps', jar, scope: 'asciiSmallHeader');
    final archive = _capture(jar);
    final before = jsonEncode(archive);
    final domains = archive['domainBuckets']! as List<Map<String, Object?>>;
    expect(domains.map((bucket) => bucket['keyUnits']).toList(), [
      <int>[],
      'first-domain'.codeUnits,
      'last-domain'.codeUnits,
    ]);
    expect(domains.first['paths'], isEmpty);
    expect(jsonEncode(_capture(jar)), before);
    // The returned arrays own their units and do not alias a live Map.
    (domains[1]['keyUnits']! as List<int>)[0] = 0;
    expect(jar.domainCookies.keys.toList(), ['', 'first-domain', 'last-domain']);
    expect(jsonEncode(_capture(jar)), before);
  });

  test('entry map key remains independent from original Cookie name and path', () {
    final cookie = Cookie('actual-name', 'synthetic-value')
      ..domain = '.different-cookie-domain'
      ..path = '/different-cookie-path'
      ..secure = true
      ..httpOnly = true
      ..sameSite = SameSite.strict
      ..maxAge = 3600
      ..expires = DateTime.utc(2040, 1, 1, 0, 0, 0, 1, 234);
    final jar = _single(cookie, key: 'different-map-key');
    final entry = _entry(_capture(jar));
    expect(entry['keyUnits'], 'different-map-key'.codeUnits);
    expect(entry['nameUnits'], 'actual-name'.codeUnits);
    expect(entry['cookieDomainUnits'], '.different-cookie-domain'.codeUnits);
    expect(entry['cookiePathUnits'], '/different-cookie-path'.codeUnits);
    expect(entry['sameSite'], 'Strict');
    expect(entry['expiresMicroseconds'], DateTime.utc(2040, 1, 1, 0, 0, 0, 1, 234).microsecondsSinceEpoch);
    expect(entry['secure'], true);
    expect(entry['httpOnly'], true);
    record('map-key-distinct-from-cookie-name', jar);
  });

  test('canonical-equivalent and nonpaired UTF16 keys remain distinct', () {
    final keys = [
      '',
      '\u00e9',
      'e\u0301',
      '\u{1f600}',
      '\ue000',
      String.fromCharCodes([0xd800]),
      String.fromCharCodes([0xdc00]),
    ];
    final jar = DefaultCookieJar(ignoreExpires: true);
    for (var index = 0; index < keys.length; index++) {
      final key = keys[index];
      jar
        ..domainCookies[key] = {
          key: {key: SerializableCookie(Cookie('synthetic', 'value-$index'))},
        }
        ..hostCookies[key] = {};
    }
    final archive = _capture(jar);
    final domains = archive['domainBuckets']! as List<Map<String, Object?>>;
    expect(domains.map((bucket) => bucket['keyUnits']).toList(), [
      for (final key in keys) key.codeUnits,
    ]);
    expect(domains.length, keys.length);
    record('exact-utf16-keys-in-all-three-map-levels', jar);
  });

  test('required nullable fields distinguish null empty and actual SameSite labels', () {
    final nullJar = _single(Cookie('null-attributes', 'synthetic'));
    final nullEntry = _entry(_capture(nullJar));
    for (final key in [
      'cookieDomainUnits',
      'cookiePathUnits',
      'sameSite',
      'expiresMicroseconds',
      'maxAgeSeconds',
    ]) {
      expect(nullEntry.containsKey(key), true);
      expect(nullEntry[key], null);
    }
    record('nil-required-attributes', nullJar);
    final emptyJar = _single(
      Cookie('empty-attributes', 'synthetic')
        ..domain = ''
        ..path = '',
    );
    final emptyEntry = _entry(_capture(emptyJar));
    expect(emptyEntry['cookieDomainUnits'], <int>[]);
    expect(emptyEntry['cookiePathUnits'], <int>[]);
    record('empty-cookie-domain-path-attributes', emptyJar);
    for (final sameSite in SameSite.values) {
      final jar = _single(Cookie('same-site', 'synthetic')..sameSite = sameSite);
      expect(_entry(_capture(jar))['sameSite'], sameSite.name);
      record('actual-same-site-${sameSite.name}', jar);
    }
  });

  test('integer time bounds are explicit representation seeds not clock proof', () {
    const maximumInt64 = 9223372036854775807;
    const minimumInt64 = -9223372036854775808;
    const dateTimeLimit = 8640000000000000000;
    for (final expiry in [-dateTimeLimit, dateTimeLimit]) {
      for (final maxAge in [minimumInt64, maximumInt64]) {
        final jar = _single(
          Cookie('time-bounds', 'synthetic')
            ..expires = DateTime.fromMicrosecondsSinceEpoch(expiry, isUtc: true)
            ..maxAge = maxAge,
        );
        jar.domainCookies['domain-key']!['path-key']!['map-key']!
            .createTimeStamp = maximumInt64;
        final entry = _entry(_capture(jar));
        expect(entry['expiresMicroseconds'], expiry);
        expect(entry['maxAgeSeconds'], maxAge);
        expect(entry['createdSeconds'], maximumInt64);
        record(
          'int64-and-datetime-$expiry-$maxAge',
          jar,
          creationPolicy: 'explicitSyntheticSeedForRepresentationOnly',
        );
      }
    }
    final invalid = _single(Cookie('creation', 'synthetic'));
    invalid.domainCookies['domain-key']!['path-key']!['map-key']!
        .createTimeStamp = -1;
    expect(() => _capture(invalid), _exportFailure('invalidCreationTime'));
    limits.add({'id': 'negative-created-seconds', 'outcome': 'rejected'});
  });

  test('live production parser and header expose complete current attributes', () async {
    const url = 'https://api.bilibili.com/x/test';
    final jar = DefaultCookieJar();
    final fields = [
      'same=root; Domain=.bilibili.com; Path=/; HttpOnly; SameSite=Lax',
      'same=nested; Domain=.bilibili.com; Path=/x; Secure; Max-Age=3600',
      'host=pathless',
      'empty=gone; Domain=.bilibili.com; Path=/empty; Max-Age=0',
    ];
    final parsed = parseResponseCookieHeaders(
      fields,
      source: SetCookieSource.separatedFields,
    );
    await jar.saveFromResponse(Uri.parse(url), parsed.cookies);
    expect(jar.domainCookies['bilibili.com']!['/empty'], isEmpty);
    final loaded = await jar.loadForRequest(Uri.parse(url));
    final header = AccountManager.getCookies(loaded);
    expect(header, 'host=pathless; same=nested; same=root');
    record('live-production-response-with-full-attrs', jar, scope: 'asciiSmallHeader');
    cases.last['responseFields'] = fields;
    cases.last['url'] = url;
    cases.last['headerUnits'] = header.codeUnits;
    final provenance = _capture(jar)['provenance']! as Map<String, Object?>;
    expect(provenance['priorPersistence'], 'unknown');
    expect(provenance['legacyHiveAttributesIncomplete'], true);
    expect(provenance['currentBucketOrderComplete'], true);
  });

  test('real Hive type8 reopen records lost attrs and buckets without inventing history', () async {
    final jar = DefaultCookieJar();
    final uri = Uri.parse('https://api.bilibili.com/x/test');
    await jar.saveFromResponse(uri, [
      Cookie.fromSetCookieValue(
        'root=synthetic-root; Domain=.bilibili.com; Path=/; Secure; HttpOnly; '
        'SameSite=Strict; Max-Age=3600; Expires=Sun, 01 Jan 2040 00:00:00 GMT',
      ),
      Cookie.fromSetCookieValue('nested=synthetic-nested; Domain=.bilibili.com; Path=/x'),
      Cookie.fromSetCookieValue('host=synthetic-host; Path=/x'),
      Cookie.fromSetCookieValue('gone=old; Domain=.bilibili.com; Path=/empty; Max-Age=0'),
    ]);
    jar
      ..domainCookies['empty-no-paths'] = {}
      ..hostCookies['empty-host'] = {};
    final before = _capture(jar);
    final beforeHeader = AccountManager.getCookies(await jar.loadForRequest(uri));
    final box = await Hive.openBox<DefaultCookieJar>('native-ordered-cookie-fixture');
    await box.put('synthetic-jar', jar);
    await box.flush();
    await box.close();
    final reopenStarted = DateTime.now().microsecondsSinceEpoch;
    final reopenedBox = await Hive.openBox<DefaultCookieJar>('native-ordered-cookie-fixture');
    final reopened = reopenedBox.get('synthetic-jar')!;
    final reopenFinished = DateTime.now().microsecondsSinceEpoch;
    final after = NativeOrderedCookieJarExporter.export(
      reopened,
      priorPersistence: NativeOrderedCookiePriorPersistence.legacyHiveReopened,
    );
    final afterHeader = AccountManager.getCookies(await reopened.loadForRequest(uri));
    expect(reopened, isNot(same(jar)));
    expect(reopened.ignoreExpires, true);
    expect(reopened.domainCookies.keys.toList(), ['bilibili.com']);
    expect(reopened.domainCookies['bilibili.com']!.keys.toList(), ['/']);
    expect(reopened.hostCookies, isEmpty);
    final restored = reopened.domainCookies['bilibili.com']!['/']!['root']!;
    expect(restored.cookie.secure, false);
    expect(restored.cookie.httpOnly, false);
    expect(restored.cookie.sameSite, null);
    expect(restored.cookie.maxAge, null);
    expect(restored.cookie.expires, null);
    expect(restored.cookie.domain, '.bilibili.com');
    expect(restored.cookie.path, '/');
    expect(restored.createTimeStamp, greaterThanOrEqualTo(reopenStarted ~/ 1000000));
    expect(restored.createTimeStamp, lessThanOrEqualTo(reopenFinished ~/ 1000000));
    expect(afterHeader, 'root=synthetic-root');
    expect(beforeHeader, isNot(afterHeader));
    expect(after['provenance'], {
      'capture': 'live',
      'priorPersistence': 'legacyHiveReopened',
      'legacyHiveAttributesIncomplete': true,
      'currentBucketOrderComplete': true,
    });
    cases.add({
      'id': 'actual-hive-type8-reopened',
      'compatibilityScope': 'asciiSmallHeader',
      'creationPolicy': 'actualHiveReaderRegeneratedSerializableCookie',
      'captureStartedMicroseconds': reopenStarted,
      'captureFinishedMicroseconds': reopenFinished,
      'jar': after,
    });
    await File('${directory.path}/hive-reopened.json').writeAsString(jsonEncode({
      'schemaVersion': 1,
      'runtimeCutover': false,
      'source': 'actual production BiliCookieJarAdapter type8 / Hive CE 2.20.0',
      'reopenStartedMicroseconds': reopenStarted,
      'reopenFinishedMicroseconds': reopenFinished,
      'before': before,
      'after': after,
      'beforeHeaderUnits': beforeHeader.codeUnits,
      'afterHeaderUnits': afterHeader.codeUnits,
      'actualLosses': [
        'ignoreExpires-policy-changed-to-true',
        'non-root-domain-paths-and-host-buckets',
        'empty-buckets',
        'secure-httpOnly-sameSite-expires-maxAge',
        'creation-seconds-regenerated',
      ],
    }));
    await reopenedBox.close();
  });

  test('per-string export boundaries reject before publishing a partial archive', () {
    for (final kind in ['map-key', 'name', 'value', 'domain', 'path']) {
      final limit = switch (kind) {
        'name' => NativeOrderedCookieJarExporter.maxNameUnits,
        'value' => NativeOrderedCookieJarExporter.maxValueUnits,
        _ => NativeOrderedCookieJarExporter.maxKeyUnits,
      };
      DefaultCookieJar make(int count) {
        final text = 'a' * count;
        final cookie = Cookie(kind == 'name' ? text : 'name', kind == 'value' ? text : 'value');
        if (kind == 'domain') {
          cookie.domain = text;
        }
        if (kind == 'path') {
          cookie.path = text;
        }
        return _single(cookie, key: kind == 'map-key' ? text : 'map-key');
      }

      expect(() => _capture(make(limit)), returnsNormally);
      final invalid = make(limit + 1);
      final originalKeys = invalid.domainCookies.keys.toList();
      expect(() => _capture(invalid), _exportFailure('stringCapacityExceeded'));
      expect(invalid.domainCookies.keys.toList(), originalKeys);
      limits.add({'id': '$kind-units', 'limit': limit, 'atLimit': 'accepted', 'overLimit': 'rejected'});
    }
  });

  test('total bucket entry and UTF16 budgets fail explicitly rather than truncating', () {
    final buckets = DefaultCookieJar();
    for (var index = 0; index < NativeOrderedCookieJarExporter.maxBuckets; index++) {
      buckets.domainCookies['$index'] = {};
    }
    expect(() => _capture(buckets), returnsNormally);
    buckets.hostCookies['one-too-many'] = {};
    expect(() => _capture(buckets), _exportFailure('bucketCapacityExceeded'));
    limits.add({'id': 'total-buckets', 'atLimit': 'accepted', 'overLimit': 'rejected'});

    final entries = DefaultCookieJar(ignoreExpires: true)
      ..domainCookies['domain'] = {'/': {}};
    final shared = SerializableCookie(Cookie('name', 'value'));
    for (var index = 0; index < NativeOrderedCookieJarExporter.maxCookies; index++) {
      entries.domainCookies['domain']!['/']!['$index'] = shared;
    }
    expect(() => _capture(entries), returnsNormally);
    entries.domainCookies['domain']!['/']!['one-too-many'] = shared;
    expect(() => _capture(entries), _exportFailure('cookieCapacityExceeded'));
    limits.add({'id': 'total-entries', 'atLimit': 'accepted', 'overLimit': 'rejected'});

    final units = DefaultCookieJar(ignoreExpires: true)
      ..domainCookies['domain'] = {'/': {}};
    final longValue = SerializableCookie(Cookie('name', 'v' * NativeOrderedCookieJarExporter.maxValueUnits));
    for (var index = 0; index < 33; index++) {
      units.domainCookies['domain']!['/']!['$index'] = longValue;
    }
    expect(() => _capture(units), _exportFailure('unitCapacityExceeded'));
    limits.add({'id': 'total-utf16-units', 'overLimit': 'rejected'});
  });
}
