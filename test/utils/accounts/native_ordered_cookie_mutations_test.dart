import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/native_accounts/native_ordered_cookie_jar_export.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/accounts/account_manager/response_cookie_headers.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

typedef _Action = FutureOr<void> Function();

/// This producer invokes the pinned CookieJar and the production response
/// parser/header writer. It does not provide a second cookie implementation.
/// DateTime.now inside SerializableCookie cannot be replaced by a fake clock.
class _Trajectory {
  final String id;
  final DefaultCookieJar jar;
  final bool headerSupported;
  final List<Map<String, Object?>> steps = [];

  _Trajectory(this.id, {bool ignoreExpires = false, this.headerSupported = true})
    : jar = DefaultCookieJar(ignoreExpires: ignoreExpires);

  Map<String, Object?> export() => NativeOrderedCookieJarExporter.export(jar);

  Iterable<SerializableCookie> get stored sync* {
    for (final buckets in [jar.domainCookies, jar.hostCookies]) {
      for (final paths in buckets.values) {
        for (final cookies in paths.values) {
          yield* cookies.values;
        }
      }
    }
  }

  Future<void> step(
    String label,
    Map<String, Object?> operation,
    _Action action, {
    List<String> requests = const ['https://api.bilibili.com/x/test'],
    bool expectFailure = false,
  }) async {
    final createsCookies = const {
      'saveFromSeparatedResponseFields',
      'seedPublicUTF16Maps',
      'seedPublicUTF16Overwrite',
    }.contains(operation['kind']);
    if (createsCookies) {
      // The native batch candidate injects one clock. Start this short actual
      // operation in the first half of a real second, then measure its window.
      // This is neither a fake DateTime nor a retry of a Cookie mutation.
      final offset = DateTime.now().microsecondsSinceEpoch % 1000000;
      if (offset >= 500000) {
        await Future<void>.delayed(Duration(microseconds: 1050000 - offset));
      }
    }
    final before = jsonEncode(export());
    final started = DateTime.now().microsecondsSinceEpoch;
    Object? failure;
    try {
      await action();
    } catch (error) {
      failure = error;
    }
    final finished = DateTime.now().microsecondsSinceEpoch;
    if (expectFailure) {
      expect(failure, isNotNull, reason: '$id/$label must reject');
      expect(jsonEncode(export()), before, reason: '$id/$label must not mutate');
    } else {
      expect(failure, isNull, reason: '$id/$label failed: $failure');
      if (createsCookies) {
        expect(started ~/ 1000000, finished ~/ 1000000,
          reason: '$id/$label has an ambiguous actual creation clock window');
      }
    }
    final captured = export();
    final observations = <Map<String, Object?>>[];
    if (headerSupported) {
      // Keep the existing native selector's proved range. Unicode key fixtures
      // below exercise representation only and never widen header support.
      expect(stored.length, lessThanOrEqualTo(32));
      for (final buckets in [jar.domainCookies, jar.hostCookies]) {
        for (final bucket in buckets.entries) {
          expect(bucket.key.codeUnits.every((unit) => unit < 128), true);
          for (final path in bucket.value.keys) {
            expect(path.codeUnits.every((unit) => unit < 128), true);
          }
        }
      }
      for (final url in requests) {
        final uri = Uri.parse(url);
        expect(uri.host, isNotEmpty);
        expect(uri.host.codeUnits.every((unit) => unit < 128), true);
        expect(uri.path.codeUnits.every((unit) => unit < 128), true);
        final offset = DateTime.now().microsecondsSinceEpoch % 1000000;
        if (offset >= 950000) {
          await Future<void>.delayed(Duration(microseconds: 1050000 - offset));
        }
        final loadStarted = DateTime.now().microsecondsSinceEpoch;
        final loaded = await jar.loadForRequest(uri);
        final loadFinished = DateTime.now().microsecondsSinceEpoch;
        expect(loadStarted ~/ 1000000, loadFinished ~/ 1000000,
          reason: '$id/$label has an ambiguous actual load clock window');
        // Capture CookieJar order before getCookies sorts its input in place.
        final loadedOrder = [for (final cookie in loaded) _cookie(cookie)];
        final header = AccountManager.getCookies(loaded);
        observations.add({
          'url': url,
          'startedMicroseconds': loadStarted,
          'finishedMicroseconds': loadFinished,
          'loaded': loadedOrder,
          'header': header,
          'headerUnits': header.codeUnits,
        });
      }
    }
    expect(jsonEncode(export()), jsonEncode(captured),
      reason: 'load/header must not mutate $id/$label jar');
    steps.add({
      'label': label,
      'operation': operation,
      'outcome': failure == null ? 'applied' : 'rejectedBeforeMutation',
      'errorType': switch (failure) {
        null => null,
        FormatException() => 'FormatException',
        ArgumentError() => 'ArgumentError',
        _ => 'unexpected',
      },
      'startedMicroseconds': started,
      'finishedMicroseconds': finished,
      'jar': captured,
      'requests': observations,
    });
  }

  Future<void> save(
    String label,
    String url,
    List<String> fields, {
    List<String> requests = const ['https://api.bilibili.com/x/test'],
    bool expectFailure = false,
  }) => step(label, {
    'kind': 'saveFromSeparatedResponseFields',
    'url': url,
    'fields': fields,
    'source': 'separatedFields',
  }, () async {
    // This is the exact production whole-batch parser; a bad field must throw
    // before saveFromResponse can apply any valid prefix.
    final parsed = parseResponseCookieHeaders(
      fields,
      source: SetCookieSource.separatedFields,
    );
    await jar.saveFromResponse(Uri.parse(url), parsed.cookies);
  }, requests: requests, expectFailure: expectFailure);

  Future<void> delete(String label, String url, bool shared) => step(label, {
    'kind': 'delete', 'url': url, 'withDomainSharedCookie': shared,
  }, () => jar.delete(Uri.parse(url), shared));

  Map<String, Object?> toJson() => {
    'id': id,
    'compatibilityScope': headerSupported ? 'asciiSmallHeader' : 'representationOnly',
    'steps': steps,
  };
}

Map<String, Object?> _cookie(Cookie cookie) => {
  'nameUnits': cookie.name.codeUnits,
  'valueUnits': cookie.value.codeUnits,
  'cookieDomainUnits': cookie.domain?.codeUnits,
  'cookiePathUnits': cookie.path?.codeUnits,
  'secure': cookie.secure,
  'httpOnly': cookie.httpOnly,
  'sameSite': cookie.sameSite?.name,
  'expiresMicroseconds': cookie.expires?.microsecondsSinceEpoch,
  'maxAgeSeconds': cookie.maxAge,
};

String _header(_Trajectory trace, String url) {
  final requests = trace.steps.last['requests']! as List<Map<String, Object?>>;
  return requests.singleWhere((request) => request['url'] == url)['header']! as String;
}

void main() {
  late AccountTestStorage storage;
  final trajectories = <_Trajectory>[];
  const url = 'https://api.bilibili.com/x/test';
  setUpAll(() async { storage = await AccountTestStorage.open(); });
  tearDownAll(() async {
    final directory = Directory('build/native-ordered-cookie-check');
    await directory.create(recursive: true);
    await File('${directory.path}/mutations.json').writeAsString(jsonEncode({
      'schemaVersion': 1,
      'runtimeCutover': false,
      'source': 'actual CookieJar 4.0.9 / production separated-field parser / AccountManager.getCookies',
      'clockPolicy': {
        'kind': 'actualDartDateTimeNow',
        'injectedClock': false,
        'creationSeconds': 'observed from actual SerializableCookie after each operation',
        'operationAndLoadWindows': 'actual started/finished microseconds; no invented exact clock',
        'expiryEdges': 'past/future separated from now; elapsed case uses real wall time',
        'exactBoundaryProof': false,
      },
      'hiveReopenEvidence': 'hive-reopened.json from the distinct actual Hive export fixture',
      'trajectories': [for (final trace in trajectories) trace.toJson()],
    }));
    await storage.close();
  });

  test('actual expired saves retain empty domain host path and name buckets', () async {
    final trace = _Trajectory('empty-buckets');
    trajectories.add(trace);
    await trace.step('initial', {'kind': 'capture'}, () {});
    await trace.save('empty-domain-and-path-keys', url, [
      'gone=old; Domain=; Path=; Max-Age=0',
      'gone=old; Domain=.bilibili.com; Path=/; Max-Age=0',
    ]);
    expect(trace.jar.domainCookies['']![''], isEmpty);
    expect(trace.jar.domainCookies['bilibili.com']!['/'], isEmpty);
    await trace.save('host-default-empty-path', 'https://api.bilibili.com/video', [
      'gone=old; Max-Age=0',
    ]);
    expect(trace.jar.hostCookies['api.bilibili.com']![''], isEmpty);
    await trace.save('host-default-root-for-empty-request-path', 'https://api.bilibili.com', [
      'gone=old; Max-Age=0',
    ]);
    expect(trace.jar.hostCookies['api.bilibili.com']!['/'], isEmpty);
    await trace.save('empty-uri-host', 'https:///video', ['gone=old; Max-Age=0']);
    expect(trace.jar.hostCookies['']![''], isEmpty);
    await trace.step('public-maps-with-no-paths', {
      'kind': 'seedPublicEmptyBuckets',
      'domainKeyUnits': 'domain-with-no-paths'.codeUnits,
      'hostKeyUnits': 'host-with-no-paths'.codeUnits,
    }, () {
      // No save can create a bucket without paths. These are explicit public
      // Map states, not an invented response parsing behavior.
      trace.jar
        ..domainCookies['domain-with-no-paths'] = {}
        ..hostCookies['host-with-no-paths'] = {};
    });
    expect(trace.jar.domainCookies['domain-with-no-paths'], isEmpty);
    expect(trace.jar.hostCookies['host-with-no-paths'], isEmpty);
  });

  test('overwrite preserves insertion order and expired remove then reinsert appends', () async {
    final trace = _Trajectory('overwrite-remove-reinsert');
    trajectories.add(trace);
    await trace.save('insert-domain-and-host', url, [
      'a=domain-a; Domain=.bilibili.com; Path=/x',
      'b=domain-b; Domain=.bilibili.com; Path=/x',
      'a=host-a; Path=/x',
      'b=host-b; Path=/x',
    ]);
    final firstCreated = trace.jar.domainCookies['bilibili.com']!['/x']!['a']!.createTimeStamp;
    await trace.step('real-wall-clock-advance', {'kind': 'waitRealWallTime', 'minimumMilliseconds': 1100},
      () => Future<void>.delayed(const Duration(milliseconds: 1100)));
    await trace.save('overwrite-a', url, [
      'a=domain-new; Domain=.bilibili.com; Path=/x',
      'a=host-new; Path=/x',
    ]);
    expect(trace.jar.domainCookies['bilibili.com']!['/x']!.keys.toList(), ['a', 'b']);
    expect(trace.jar.hostCookies['api.bilibili.com']!['/x']!.keys.toList(), ['a', 'b']);
    expect(trace.jar.domainCookies['bilibili.com']!['/x']!['a']!.createTimeStamp, greaterThan(firstCreated));
    await trace.save('expired-replacement-removes-a', url, [
      'a=deleted; Domain=.bilibili.com; Path=/x; Max-Age=0',
      'a=deleted; Path=/x; Max-Age=0',
    ]);
    expect(trace.jar.domainCookies['bilibili.com']!['/x']!.keys.toList(), ['b']);
    await trace.save('reinsert-a-after-b', url, [
      'a=domain-return; Domain=.bilibili.com; Path=/x',
      'a=host-return; Path=/x',
    ]);
    expect(trace.jar.domainCookies['bilibili.com']!['/x']!.keys.toList(), ['b', 'a']);
    expect(trace.jar.hostCookies['api.bilibili.com']!['/x']!.keys.toList(), ['b', 'a']);
  });

  test('actual host path sort domain insertion and final original path header order', () async {
    final trace = _Trajectory('host-domain-header-order');
    trajectories.add(trace);
    const requests = [
      url, 'https://api.bilibili.com/X/TEST', 'https://bilibili.com/x/test',
      'https://notbilibili.com/x/test', 'https://api.bilibili.com/docsets',
    ];
    await trace.save('domain-insertion-order', url, [
      'same=domain-root; Domain=.bilibili.com; Path=/',
      'same=api-domain; Domain=api.bilibili.com; Path=/x',
      'same=domain-nested; Domain=.bilibili.com; Path=/x',
      'case=domain-uppercase; Domain=.bilibili.com; Path=/X',
    ], requests: requests);
    await trace.save('host-original-nil-path', url, ['same=host-nil-path'], requests: requests);
    expect(trace.jar.hostCookies['api.bilibili.com']!['/x']!['same']!.cookie.path, null);
    expect(_header(trace, url),
      'same=host-nil-path; same=domain-nested; case=domain-uppercase; '
      'same=api-domain; same=domain-root');
    await trace.save('host-path-length-sort', url, [
      'same=host-root; Path=/',
      'same=host-nested; Path=/x',
      'deeper=host-deep; Path=/x/test',
    ], requests: requests);
    // The nil original Cookie.path above still chose the /x bucket. Saving the
    // same name with Path=/x overwrites it, so the final jar/header has no nil
    // path Cookie; only the preceding actual step proves nil-first ordering.
    expect(trace.jar.hostCookies['api.bilibili.com']!['/x']!['same']!.cookie.path, '/x');
    expect(trace.jar.hostCookies['api.bilibili.com']!['/x']!['same']!.cookie.value, 'host-nested');
    expect(_header(trace, url),
      'deeper=host-deep; same=host-nested; same=domain-nested; '
      'case=domain-uppercase; same=api-domain; same=host-root; same=domain-root');
    expect(_header(trace, url).split('same=').length - 1, 5);
    expect(trace.jar.domainCookies.keys.toList(), ['bilibili.com', 'api.bilibili.com']);
    expect(trace.jar.hostCookies['api.bilibili.com']!.keys.toList(), ['/x', '/', '/x/test']);
    expect(_header(trace, 'https://notbilibili.com/x/test'), isEmpty);
  });

  test('delete ignores paths false retains shared domains true removes matching domains', () async {
    final trace = _Trajectory('delete-false-true-all');
    trajectories.add(trace);
    await trace.save('seed-target', url, [
      'root=domain; Domain=.bilibili.com; Path=/',
      'api=domain; Domain=api.bilibili.com; Path=/x',
      'other=domain; Domain=other.example; Path=/',
      'host=root; Path=/', 'host=nested; Path=/x',
    ]);
    await trace.save('seed-other-host', 'https://other.example/x', ['other=host; Path=/']);
    await trace.delete('delete-host-only-ignores-path', 'https://api.bilibili.com/unrelated', false);
    expect(trace.jar.hostCookies.containsKey('api.bilibili.com'), false);
    expect(trace.jar.domainCookies.keys.toList(), ['bilibili.com', 'api.bilibili.com', 'other.example']);
    await trace.save('reinsert-host', url, ['host=returned; Path=/x']);
    expect(trace.jar.hostCookies.keys.toList(), ['other.example', 'api.bilibili.com']);
    await trace.delete('delete-host-and-matching-domain-buckets', 'https://api.bilibili.com/no/path', true);
    expect(trace.jar.domainCookies.keys.toList(), ['other.example']);
    expect(trace.jar.hostCookies.keys.toList(), ['other.example']);
    await trace.step('delete-all', {'kind': 'deleteAll'}, trace.jar.deleteAll);
    expect(trace.jar.domainCookies, isEmpty);
    expect(trace.jar.hostCookies, isEmpty);
    await trace.save('new-first-bucket-after-clear', url, ['new=first; Domain=.bilibili.com; Path=/']);
  });

  for (final ignoreExpires in [false, true]) {
    test('actual expiry save and ignoreExpires=$ignoreExpires are distinct', () async {
      final trace = _Trajectory('expiry-save-$ignoreExpires', ignoreExpires: ignoreExpires);
      trajectories.add(trace);
      await trace.save('max-age-and-expiry-both-checked', url, [
        'zero=removed; Domain=.bilibili.com; Path=/; Max-Age=0',
        'negative=removed; Path=/; Max-Age=-1',
        'past=removed; Domain=.bilibili.com; Path=/; Expires=Wed, 01 Jan 2020 00:00:00 GMT',
        'future=retained; Domain=.bilibili.com; Path=/; Expires=Sun, 01 Jan 2040 00:00:00 GMT',
        'max-age-with-past=removed; Path=/; Max-Age=3600; Expires=Wed, 01 Jan 2020 00:00:00 GMT',
        'zero-with-future=removed; Path=/; Max-Age=0; Expires=Sun, 01 Jan 2040 00:00:00 GMT',
      ]);
      expect(trace.stored.length, ignoreExpires ? 6 : 1);
      expect(_header(trace, url), contains('future=retained'));
      expect(_header(trace, url).contains('max-age-with-past=removed'), ignoreExpires);
    });
  }

  test('actual elapsed clock and secure OR expiry legacy request behavior', () async {
    final trace = _Trajectory('elapsed-expiry-secure-legacy');
    trajectories.add(trace);
    const requests = [url, 'http://api.bilibili.com/x/test'];
    await trace.save('save-short-lived-and-live-secure', url, [
      'ordinary=short; Path=/x; Max-Age=1',
      'secure=short; Secure; Path=/x; Max-Age=1',
      'secure_live=retained; Secure; Path=/x',
    ], requests: requests);
    final created = trace.jar.hostCookies['api.bilibili.com']!['/x']!['ordinary']!.createTimeStamp;
    await trace.step('actual-time-expiry-load-keeps-maps', {
      'kind': 'waitRealWallTime', 'minimumMilliseconds': 2100,
    }, () => Future<void>.delayed(const Duration(milliseconds: 2100)), requests: requests);
    expect(DateTime.now().millisecondsSinceEpoch ~/ 1000 - created, greaterThanOrEqualTo(1));
    expect(trace.stored.length, 3, reason: 'load does not delete expired entries');
    expect(_header(trace, url), 'secure=short; secure_live=retained');
    expect(_header(trace, 'http://api.bilibili.com/x/test'), 'secure_live=retained');
  });

  test('whole actual production batch parser rejects bad field without valid prefix writes', () async {
    final trace = _Trajectory('bad-batch-all-or-nothing');
    trajectories.add(trace);
    await trace.save('existing', url, ['existing=retained; Domain=.bilibili.com; Path=/']);
    for (final fields in [
      ['new=must-not-write; Path=/x', 'bad name=value'],
      ['existing=must-not-overwrite; Domain=.bilibili.com; Path=/', '=missing', 'last=must-not-write'],
    ]) {
      await trace.save('reject-bad-field-${fields.length}', url, fields, expectFailure: true);
    }
    expect(trace.stored.single.cookie.value, 'retained');
    await trace.save('good-batch-after-rejection', url, ['new=finally-written; Path=/x']);
  });

  test('UTF16 public map keys remain distinct including nonpaired surrogates', () async {
    final trace = _Trajectory('utf16-key-representation', headerSupported: false);
    trajectories.add(trace);
    final keys = [
      '', '\u00e9', 'e\u0301', '\u{1f600}', '\ue000',
      String.fromCharCodes([0xd800]), String.fromCharCodes([0xdc00]),
    ];
    await trace.step('seed-exact-public-map-keys', {
      'kind': 'seedPublicUTF16Maps',
      'keys': [for (final key in keys) key.codeUnits],
      'requestHeaderSupported': false,
    }, () {
      for (var index = 0; index < keys.length; index++) {
        final key = keys[index];
        trace.jar
          ..domainCookies[key] = {
            key: {key: SerializableCookie(Cookie('synthetic', 'value-$index'))},
            'empty-name-map': {},
          }
          ..hostCookies[key] = {};
      }
    });
    expect(trace.jar.domainCookies.length, keys.length);
    expect(trace.jar.domainCookies.keys.map((key) => key.codeUnits).toList(),
      keys.map((key) => key.codeUnits).toList());
    await trace.step('overwrite-canonical-distinct-key', {
      'kind': 'seedPublicUTF16Overwrite', 'keyUnits': '\u00e9'.codeUnits,
    }, () {
      trace.jar.domainCookies['\u00e9']!['\u00e9']!['\u00e9'] =
        SerializableCookie(Cookie('synthetic', 'replacement'));
    });
    expect(trace.jar.domainCookies['e\u0301']!['e\u0301']!['e\u0301']!.cookie.value, 'value-2');
    await trace.step('remove-public-key', {
      'kind': 'removePublicDomainBucket', 'keyUnits': '\u00e9'.codeUnits,
    }, () { trace.jar.domainCookies.remove('\u00e9'); });
    await trace.step('reinsert-public-key-at-end', {
      'kind': 'reinsertPublicDomainBucket', 'keyUnits': '\u00e9'.codeUnits,
    }, () { trace.jar.domainCookies['\u00e9'] = {}; });
    expect(trace.jar.domainCookies.keys.last, '\u00e9');
    await trace.step('actual-delete-all-utf16-maps', {'kind': 'deleteAll'}, trace.jar.deleteAll);
    expect(trace.jar.domainCookies, isEmpty);
    expect(trace.jar.hostCookies, isEmpty);
  });
}
