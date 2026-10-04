import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/retry_interceptor.dart';
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
        expect(policy['followRedirects'], isFalse); // Endpoint override of true BaseOptions.
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
