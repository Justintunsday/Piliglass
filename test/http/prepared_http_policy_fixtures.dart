import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_http/native_http_request_lease_bridge.dart';
import 'package:PiliPlus/services/native_http/native_http_request_lease_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/response_cookie_headers.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import '../utils/accounts/account_test_storage.dart';

int _id = 0;
String _requestID() => 'c0000000-0000-4000-8000-${(++_id).toString().padLeft(12, '0')}';

void runPreparedHTTPPolicyFixtures({required bool http2}) {
  late AccountTestStorage storage;
  late LoginAccount account;
  late BaseOptions originalOptions;
  final services = <NativeHTTPRequestLeaseService>[];

  setUpAll(() async {
    storage = await AccountTestStorage.open(http2: http2, retry: 2, replaceHTTPAdapter: false);
  });
  setUp(() async {
    await GStorage.setting.putAll({
      SettingBoxKey.enableSystemProxy: false,
      SettingBoxKey.badCertificateCallback: false,
      SettingBoxKey.retryCount: 2,
      SettingBoxKey.retryDelay: 500,
    });
    Request.resetAdaptersForNetworkChange();
    originalOptions = Request.dio.options;
    // Isolate mutable options; production main/clone normally share this object.
    Request.dio.options = originalOptions.copyWith();
    Request.dio.interceptors
      ..removeWhere((value) => value is RetryInterceptor)
      ..add(RetryInterceptor(Request.dio, 2, 500));
    if (http2) {
      Request.http11Dio.options = Request.dio.options;
      Request.http11Dio.interceptors
        ..removeWhere((value) => value is RetryInterceptor)
        ..add(RetryInterceptor(Request.http11Dio, 2, 500));
    }
    account = LoginAccount(BiliCookieJar.fromJson({
      'DedeUserID': '${1000 + _id}', 'bili_jct': 'synthetic-csrf', 'SESSDATA': 'synthetic-session',
    }), null, null)..activated = true;
    await Accounts.installCredentials(account);
    await Accounts.set(AccountType.recommend, account);
  });
  tearDown(() {
    for (final service in services) { service.dispose(); }
    services.clear();
    Request.dio.options = originalOptions;
    if (http2) Request.http11Dio.options = originalOptions;
  });
  tearDownAll(() async {
    if (http2) Request.http11Dio.close(force: true);
    await storage.close();
  });

  NativeHTTPRequestLeaseService create({Future<List<Cookie>> Function(Account, Uri)? loadCookies}) {
    final service = NativeHTTPRequestLeaseService(loadCookies: loadCookies, autoExpire: false);
    services.add(service);
    return service;
  }

  Future<void> changed(FutureOr<void> Function() mutate) async {
    final entered = Completer<void>(), release = Completer<void>();
    final service = create(loadCookies: (owner, url) async {
      entered.complete(); await release.future;
      return owner.cookieJar.loadForRequest(url);
    });
    final preparing = service.prepare(requestID: _requestID());
    final rejected = expectLater(preparing, throwsA(isA<NativeHTTPRequestLeaseException>()
        .having((error) => error.code, 'code', 'snapshotChanged')));
    await entered.future;
    try { await mutate(); } finally { release.complete(); }
    await rejected;
    expect(service.liveLeaseCount, 0);
    expect(service.pendingLeaseCount, 0);
    expect(service.tombstoneCount, 1);
    expect(account.cookieJar.toJson()['lease_cookie'], isNull);
  }

  test('pool replacement while reading cookies consumes the mixed lease', () async {
    await changed(Request.resetAdaptersForNetworkChange);
  });
  test('partial pool installation while reading cookies is rejected', () async {
    final throwing = _ThrowingCloseAdapter();
    try {
      await changed(() {
        if (http2) {
          final adapter = Request.dio.httpClientAdapter as Http2Adapter;
          adapter.fallbackAdapter.close(force: true);
          adapter.fallbackAdapter = throwing;
        } else {
          Request.dio.httpClientAdapter.close(force: true);
          Request.dio.httpClientAdapter = throwing;
        }
        Request.resetAdaptersForNetworkChange();
        expect(Request.effectiveHTTPPolicy.isDescribed, isFalse);
      });
    } finally {
      throwing.fail = false;
      Request.resetAdaptersForNetworkChange();
    }
  });
  test('microsecond timeout, encoding, base and account headers cannot change across await', () async {
    await changed(() => Request.dio.options.receiveTimeout = const Duration(microseconds: 7000001));
    await changed(() => Request.dio.options.transformTimeout = const Duration(microseconds: 7000009));
    await changed(() => Request.dio.options.followRedirects = false);
    await changed(() => Request.dio.options.headers['accept-encoding'] = 'gzip');
    await changed(() => Request.dio.options.headers['x-policy-fixture'] = 'later');
    await changed(() => account.headers['x-account-fixture'] = 'later');
    await changed(() => Request.dio.options.headers['host'] = 'invalid');
  });
  test('decoder and actual retry edits are checked without a pool reset', () async {
    final decoder = Request.dio.options.responseDecoder;
    await changed(() => Request.dio.options.responseDecoder = null);
    Request.dio.options.responseDecoder = decoder;
    await changed(() => Request.dio.options.validateStatus = (_) => true);
    await changed(() {
      Request.dio.interceptors
        ..removeWhere((value) => value is RetryInterceptor)
        ..add(RetryInterceptor(Request.dio, 0, 31));
    });
    await changed(() => Request.dio.interceptors.removeWhere((value) => value is RetryInterceptor));
  });
  test('retry uses the same owner and merges current Cookie with prior attempts', () async {
    final service = create();
    final bridge = NativeHTTPRequestLeaseBridge(service: service);
    final snapshot = await service.prepare(requestID: _requestID());
    final replacement = LoginAccount(BiliCookieJar.fromJson({
      'DedeUserID': '91001', 'SESSDATA': 'other-session',
    }), null, null)..activated = true;
    await Accounts.installCredentials(replacement);
    await Accounts.set(AccountType.recommend, replacement);
    Future<Map<String, Object?>> refresh(Object attempt) => bridge.handle('prepareNativeHTTPRetry', {
      'requestID': snapshot.requestID, 'leaseID': snapshot.leaseID, 'attempt': attempt,
    });
    expect((await refresh(true))['code'], 'invalidArguments');
    expect((await refresh(2))['code'], 'invalidRetryAttempt');
    for (final attempt in [1, 2]) {
      await account.cookieJar.saveFromResponse(snapshot.url, [Cookie('retry_fixture', 'value-$attempt')..path = '/']);
      final result = await refresh(attempt);
      expect(result['state'], 'retryPrepared');
      expect(result['executionAllowed'], isFalse);
      expect(result['attempt'], attempt);
      final header = (result['headers'] as Map)['cookie'] as String;
      expect(header, contains('SESSDATA=synthetic-session'));
      expect(header, isNot(contains('other-session')));
      expect(header, contains('retry_fixture=value-1'));
      if (attempt == 2) expect(header, contains('retry_fixture=value-2'));
      expect((await refresh(attempt))['code'], 'invalidRetryAttempt');
    }
    expect((await refresh(3))['code'], 'invalidRetryAttempt');
    expect(service.abandon(requestID: snapshot.requestID, leaseID: snapshot.leaseID).outcome.name, 'abandoned');
  });

  for (final change in ['abandoned', 'revoked', 'snapshotChanged']) {
    test('$change during retry Cookie read prevents another attempt', () async {
      final entered = Completer<void>(), release = Completer<void>();
      var loads = 0;
      final service = create(loadCookies: (owner, url) async {
        if (++loads == 2) {
          entered.complete();
          await release.future;
        }
        return owner.cookieJar.loadForRequest(url);
      });
      final bridge = NativeHTTPRequestLeaseBridge(service: service);
      final snapshot = await service.prepare(requestID: _requestID());
      Future<Map<String, Object?>> retry() => bridge.handle('prepareNativeHTTPRetry', {
        'requestID': snapshot.requestID, 'leaseID': snapshot.leaseID, 'attempt': 1,
      });
      final pending = retry();
      await entered.future;
      expect((await retry())['code'], 'retryInProgress');
      try {
        switch (change) {
          case 'abandoned':
            service.abandon(requestID: snapshot.requestID, leaseID: snapshot.leaseID);
          case 'revoked':
            await Accounts.installCredentials(LoginAccount(BiliCookieJar.fromJson({
              'DedeUserID': '${account.mid}', 'SESSDATA': 'replacement-session',
            }), null, null)..activated = true);
          case 'snapshotChanged':
            Request.resetAdaptersForNetworkChange();
        }
      } finally {
        release.complete();
      }
      final denied = await pending;
      expect(denied['code'], change);
      expect(denied['headers'], isNull);
      expect(loads, 2);
      service.abandon(requestID: snapshot.requestID, leaseID: snapshot.leaseID);
      expect(service.liveLeaseCount, 0);
    });
  }
  test('Prefs alone do not replace an effective pool or installed retry', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final service = create(loadCookies: (owner, url) async {
      entered.complete(); await release.future; return owner.cookieJar.loadForRequest(url);
    });
    final before = Request.effectiveHTTPPolicy;
    final preparing = service.prepare(requestID: _requestID());
    await entered.future;
    await GStorage.setting.putAll({
      SettingBoxKey.enableSystemProxy: true, SettingBoxKey.systemProxyHost: '127.0.0.1',
      SettingBoxKey.systemProxyPort: '8080', SettingBoxKey.retryCount: 0, SettingBoxKey.retryDelay: 1,
      SettingBoxKey.badCertificateCallback: true,
    });
    release.complete();
    final snapshot = await preparing;
    expect(snapshot.policy.values['poolGeneration'], before.poolGeneration);
    expect((snapshot.policy.values['pool'] as Map)['proxy'], isNull);
    expect((snapshot.policy.values['retry'] as Map)['count'], 2);
    expect(snapshot.executionAllowed, isFalse);
    service.abandon(requestID: snapshot.requestID, leaseID: snapshot.leaseID);
  });
  test('prepared redirects match the actual legacy SearchHttp request', () async {
    final service = create();
    final seen = <RequestOptions>[];
    final capture = InterceptorsWrapper(onRequest: (request, handler) {
      seen.add(request);
      handler.resolve(Response<Map<String, dynamic>>(
        requestOptions: request,
        statusCode: 200,
        data: {'code': 0, 'data': {'list': []}},
      ));
    });
    Request.dio.interceptors.add(capture);
    try {
      for (final followRedirects in [true, false]) {
        Request.dio.options.followRedirects = followRedirects;
        final context = await service.prepare(requestID: _requestID());
        await SearchHttp.searchTrending(limit: 10);
        expect(seen.last.uri, context.url);
        expect(seen.last.followRedirects, followRedirects);
        expect(context.policy.values['followRedirects'], seen.last.followRedirects);
        service.abandon(requestID: context.requestID, leaseID: context.leaseID);
      }
      expect(seen, hasLength(2));
    } finally {
      Request.dio.interceptors.remove(capture);
    }
  });
  test('terminal 300 uses the original allowance and the raw legacy base', () async {
    Request.dio.options
      ..followRedirects = true
      ..maxRedirects = 1;
    final service = create();
    final bridge = NativeHTTPRequestLeaseBridge(service: service);
    Future<Map<String, Object?>> finish(NativeHTTPRequestLeaseSnapshot snapshot, List<String> locations) {
      const hop = 'nested/last';
      final finalUrl = snapshot.url.resolve(hop).toString();
      return bridge.handle('finishNativeHTTPRequest', {
        'requestID': snapshot.requestID, 'leaseID': snapshot.leaseID,
        'response': {
          'url': finalUrl, 'statusCode': 300, 'cookieSource': 'separatedFields',
          'setCookieValues': ['terminal_fixture=saved'],
          'redirects': [{'statusCode': 302, 'location': hop, 'url': finalUrl}],
          'locationValues': locations,
        },
      });
    }

    Request.dio.interceptors
      ..removeWhere((value) => value is RetryInterceptor)
      ..add(RetryInterceptor(Request.dio, 0, 500));
    final retryInstalled = await service.prepare(requestID: _requestID());
    expect(retryInstalled.policy.retryInstalled, isTrue);
    expect(retryInstalled.policy.retryLimit, 0);
    Request.dio.interceptors.removeWhere((value) => value is RetryInterceptor);
    final target = retryInstalled.url.resolve('/fixture/destination/next');
    final revision = Accounts.requestRevision;
    expect((await finish(retryInstalled, [target.toString()]))['code'], 'invalidResponse');
    final relative = await service.prepare(requestID: _requestID());
    expect(relative.policy.retryInstalled, isFalse);
    expect((await finish(relative, [target.toString(), 'relative/next']))['code'], 'invalidResponse');
    expect(Accounts.requestRevision, revision);

    Request.dio.interceptors.add(RetryInterceptor(Request.dio, 2, 500));
    final noLocation = await service.prepare(requestID: _requestID());
    final receipt = await finish(noLocation, []);
    expect(receipt['state'], 'finished');
    expect(receipt['cookieCount'], 1);
    expect((await account.cookieJar.loadForRequest(noLocation.url.resolve('nested/last')))
        .any((cookie) => cookie.name == 'terminal_fixture'), isTrue);
    expect((await account.cookieJar.loadForRequest(target)).any((cookie) => cookie.name == 'terminal_fixture'), isFalse);
    expect(service.liveLeaseCount, 0);
  });

  Map<String, Object?> redirectCommand(NativeHTTPRequestLeaseSnapshot snapshot, List<String> locations) => {
    'requestID': snapshot.requestID, 'leaseID': snapshot.leaseID, 'redirectIndex': 1,
    'response': {
      'url': snapshot.url.toString(), 'statusCode': 300, 'locationValues': locations,
      'cookieSource': 'separatedFields', 'setCookieValues': <String>[],
    },
  };

  test('same-origin reissue pins the next URL, budget and subsequent Cookie reads', () async {
    Request.dio.options
      ..followRedirects = true
      ..maxRedirects = 1;
    final service = create();
    final bridge = NativeHTTPRequestLeaseBridge(service: service);
    final snapshot = await service.prepare(requestID: _requestID());
    final revision = Accounts.requestRevision;
    for (final locations in [
      ['https://other.example/next'], ['https://api.bilibili.com:8443/next'], ['http://api.bilibili.com/next'],
      ['https://user@api.bilibili.com/next'], ['/fixture/next#fragment'],
      ['/fixture/hdslb.com/next'], ['/fixture/one', '/fixture/two'], <String>[],
    ]) {
      final result = await bridge.handle('prepareNativeHTTPRedirect', redirectCommand(snapshot, locations));
      expect(result['state'], 'error', reason: '$locations');
      expect(service.liveLeaseCount, 1);
    }
    expect(Accounts.requestRevision, revision);
    final target = snapshot.url.resolve('/fixture/next/ranking?cursor=1&limit=10');
    final command = redirectCommand(snapshot, ['/fixture/next/ranking?cursor=1']);
    final next = await bridge.handle('prepareNativeHTTPRedirect', command);
    expect(next['state'], 'redirectPrepared');
    expect(next['url'], target.toString());
    expect(next['remainingRedirects'], 0);
    expect((await bridge.handle('prepareNativeHTTPRedirect', command))['code'], 'invalidRedirectAttempt');
    final stale = await bridge.handle('finishNativeHTTPRequest', {
      'requestID': snapshot.requestID, 'leaseID': snapshot.leaseID,
      'response': {'url': snapshot.url.toString(), 'statusCode': 200, 'cookieSource': 'separatedFields',
        'setCookieValues': ['stale=ignored; Path=/']},
    });
    expect(stale['code'], 'invalidRedirectAttempt');
    await account.cookieJar.saveFromResponse(target, [Cookie('new_scope', 'present')..path = '/fixture/next/']);
    final retry = await service.prepareRetry(requestID: snapshot.requestID, leaseID: snapshot.leaseID, attempt: 1);
    expect(retry['cookie'], contains('new_scope=present'));
    final receipt = await service.finish(requestID: snapshot.requestID, leaseID: snapshot.leaseID, redirectIndex: 1,
      response: NativeHTTPRequestLeaseResponse(url: target, statusCode: 200,
        cookieSource: SetCookieSource.separatedFields, setCookieValues: ['terminal=saved']));
    expect(receipt.outcome.name, 'finished');
    expect((await account.cookieJar.loadForRequest(target)).any((c) => c.name == 'terminal'), isTrue);
    expect((await account.cookieJar.loadForRequest(snapshot.url)).any((c) => c.name == 'stale'), isFalse);
  });

  test('abandon during a reissue Cookie read denies both competing attempts and the late reply', () async {
    final entered = Completer<void>(), release = Completer<void>();
    var loads = 0;
    final service = create(loadCookies: (owner, url) async {
      if (++loads == 2) { entered.complete(); await release.future; }
      return owner.cookieJar.loadForRequest(url);
    });
    final bridge = NativeHTTPRequestLeaseBridge(service: service);
    final snapshot = await service.prepare(requestID: _requestID());
    final command = redirectCommand(snapshot, ['/fixture/next']);
    final preparing = bridge.handle('prepareNativeHTTPRedirect', command);
    await entered.future;
    try {
      expect((await bridge.handle('prepareNativeHTTPRedirect', command))['code'], 'redirectInProgress');
      final retry = await bridge.handle('prepareNativeHTTPRetry', {
        'requestID': snapshot.requestID, 'leaseID': snapshot.leaseID, 'attempt': 1,
      });
      expect(retry['code'], 'retryInProgress');
      expect(service.abandon(requestID: snapshot.requestID, leaseID: snapshot.leaseID).outcome.name, 'abandoned');
    } finally {
      release.complete();
    }
    expect((await preparing)['code'], 'abandoned');
    expect(service.liveLeaseCount, 0);
    expect(loads, 2);
  });

  test('real production bridge exports composed policies for Swift consumption', () async {
    final cases = <Map<String, Object?>>[];
    Future<void> export(String name, {bool h11 = false}) async {
      final service = h11 ? NativeHTTPRequestLeaseService(
        options: () => Request.http11Dio.options, policy: () => Request.effectiveHTTP11Policy,
        autoExpire: false) : create();
      final bridge = NativeHTTPRequestLeaseBridge(service: service);
      try {
        final payload = await bridge.handle('prepareNativeHTTPRequest', {
          'requestID': _requestID(), 'purpose': 'searchTrending', 'limit': 10,
        });
        expect(payload['state'], 'prepared');
        final policy = payload['policy'] as Map;
        expect(policy['followRedirects'], isTrue); // Inherit the legacy SearchHttp request.
        expect(policy['clientMode'], h11 ? 'http11' : 'main');
        expect(policy['acceptEncoding'], (payload['headers'] as Map)['accept-encoding']);
        expect(() => policy['version'] = 2, throwsUnsupportedError);
        cases.add({'id': name, 'prepared': payload});
      } finally { bridge.dispose(); }
    }
    Request.dio.options
      ..connectTimeout = const Duration(microseconds: 10000001)
      ..receiveTimeout = const Duration(microseconds: 10000003)
      ..transformTimeout = const Duration(microseconds: 8000009)
      ..sendTimeout = const Duration(microseconds: 9000007);
    await export('retry-two');
    await export('forced-http11', h11: true);
    Request.dio.interceptors
      ..removeWhere((value) => value is RetryInterceptor)
      ..add(RetryInterceptor(Request.dio, 0, 37));
    await export('retry-installed-zero');
    Request.dio.interceptors.removeWhere((value) => value is RetryInterceptor);
    await export('retry-absent');
    Request.dio.interceptors.add(RetryInterceptor(Request.dio, -1, -7));
    await export('retry-signed-unsupported');
    Request.dio.interceptors.removeWhere((value) => value is RetryInterceptor);
    await GStorage.setting.putAll({SettingBoxKey.enableSystemProxy: true,
      SettingBoxKey.systemProxyHost: '127.0.0.1', SettingBoxKey.systemProxyPort: '-1'});
    Request.resetAdaptersForNetworkChange();
    await export('proxy-signed-unsupported');
    await GStorage.setting.put(SettingBoxKey.enableSystemProxy, false);
    Request.resetAdaptersForNetworkChange();
    final decoder = Request.dio.options.responseDecoder;
    Request.dio.options.responseDecoder = null;
    await export('unknown-decoder');
    Request.dio.options.responseDecoder = decoder;
    final oldAdapter = Request.dio.httpClientAdapter;
    final replacement = IOHttpClientAdapter();
    Request.dio.httpClientAdapter = replacement;
    try { await export('unknown-pool'); }
    finally { Request.dio.httpClientAdapter = oldAdapter; replacement.close(force: true); }
    final output = File('build/prepared-http-policy/${http2 ? 'http2' : 'http11'}.json');
    await output.parent.create(recursive: true);
    await output.writeAsString(jsonEncode({'source': 'actual Dart bridge + Hive + installed Request pool',
      'credentials': 'synthetic fixtures only; no external requests', 'http2': http2, 'cases': cases}));
  });
  test('head completion keeps original Hive owner after policy change and purpose switch', () async {
    final service = create();
    final snapshot = await service.prepare(requestID: _requestID());
    final original = account;
    final other = LoginAccount(BiliCookieJar.fromJson({'DedeUserID': '999999'}), null, null)..activated = true;
    await Accounts.installCredentials(other);
    await Accounts.set(AccountType.recommend, other);
    Request.resetAdaptersForNetworkChange();
    Request.dio.options.receiveTimeout = const Duration(microseconds: 3333333);
    final receipt = await service.finish(requestID: snapshot.requestID, leaseID: snapshot.leaseID,
      response: NativeHTTPRequestLeaseResponse(url: snapshot.url, statusCode: 403,
        cookieSource: SetCookieSource.separatedFields, setCookieValues: [
          'lease_cookie=original; Domain=.bilibili.com; Path=/', 'host_only=volatile; Path=/',
        ]));
    expect(receipt.outcome, NativeHTTPRequestLeaseOutcome.finished);
    expect(receipt.cookiesSaved, isTrue);
    expect(receipt.cookieCount, 2);
    expect((await original.cookieJar.loadForRequest(snapshot.url)).any((cookie) =>
        cookie.name == 'host_only' && cookie.value == 'volatile'), isTrue);
    await Accounts.account.flush();
    await Accounts.account.close();
    // Accounts.account is late final: reload the persisted Box independently
    // at the end of this process, rather than assigning its singleton again.
    final reopened = await Hive.openBox<LoginAccount>('account');
    final stored = reopened.get(original.storageKey)!;
    expect((await stored.cookieJar.loadForRequest(snapshot.url)).any((cookie) =>
        cookie.name == 'lease_cookie' && cookie.value == 'original'), isTrue);
    // The old Hive adapter only exports bilibili.com root domainCookies.
    // Retain its known loss as a negative assertion, not a parity claim.
    expect((await stored.cookieJar.loadForRequest(snapshot.url))
        .any((cookie) => cookie.name == 'host_only'), isFalse);
    expect((await reopened.get(other.storageKey)!.cookieJar.loadForRequest(snapshot.url))
        .any((cookie) => cookie.name == 'lease_cookie' || cookie.name == 'host_only'), isFalse);
    expect((await service.finish(requestID: snapshot.requestID, leaseID: snapshot.leaseID,
      response: NativeHTTPRequestLeaseResponse(url: snapshot.url, statusCode: 200,
        cookieSource: SetCookieSource.separatedFields))).outcome, NativeHTTPRequestLeaseOutcome.consumed);
    await reopened.close();
  });

}

class _ThrowingCloseAdapter extends IOHttpClientAdapter {
  bool fail = true;
  @override
  void close({bool force = false}) {
    if (fail) throw StateError('synthetic pool close failure');
    super.close(force: force);
  }
}
