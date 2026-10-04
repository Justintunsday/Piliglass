import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_http/native_http_request_lease_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/response_cookie_headers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

int _nextID = 0;
String _requestID() =>
    '00000000-0000-4000-8000-${(++_nextID).toRadixString(16).padLeft(12, '0')}';

Future<LoginAccount> _select(int mid) async {
  final account = LoginAccount(
    BiliCookieJar.fromJson({
      'DedeUserID': '$mid',
      'bili_jct': 'csrf-$mid',
      'SESSDATA': 'session-$mid',
    }),
    'access-$mid',
    'refresh-$mid',
  )..activated = true;
  await Accounts.installCredentials(account);
  await Accounts.set(AccountType.recommend, account);
  return account;
}

Future<Map<String, String>> _cookies(Account account, Uri uri) async => {
  for (final cookie in await account.cookieJar.loadForRequest(uri))
    cookie.name: cookie.value,
};

void main() {
  late AccountTestStorage storage;
  late Dio dio;
  late Map<String, Map<String, dynamic>> observations;
  final services = <NativeHTTPRequestLeaseService>[];
  final persisted = <Account>[];

  setUpAll(() async {
    // This same CI job must first run production Swift against actual Darwin
    // loopback HTTP. Missing wire evidence is a failure, never a skipped test.
    final report = jsonDecode(await File(
      'build/native-http-transfer-check/report.json',
    ).readAsString()) as Map<String, dynamic>;
    expect(report['status'], 'passed');
    observations = {
      for (final item in report['observations'] as List<dynamic>)
        (item as Map<String, dynamic>)['id'] as String: item,
    };
    expect(observations.length, 12);
    storage = await AccountTestStorage.open();
  });
  setUp(() async {
    await storage.reset();
    persisted.clear();
    dio = Dio(BaseOptions(baseUrl: HttpString.apiBaseUrl));
  });
  tearDown(() {
    for (final service in services) {
      service.dispose();
    }
    services.clear();
    dio.close(force: true);
  });
  tearDownAll(() => storage.close());

  NativeHTTPRequestLeaseService create() {
    final service = NativeHTTPRequestLeaseService(
      options: () => dio.options,
      autoExpire: false,
      awaitAccountPersistence: (account, saving) async {
        await saving; // The real account.onChange/Hive write has already run.
        persisted.add(account);
      },
    );
    services.add(service);
    return service;
  }

  NativeHTTPRequestLeaseResponse response(
    NativeHTTPRequestLeaseSnapshot snapshot,
    Map<String, dynamic> observed,
  ) {
    expect(observed['cookieSource'], 'foundationCombined');
    expect(observed['headCount'], 1);
    expect(observed['outcomeReturned'], isTrue);
    // Swift separately verifies the actual loopback URL/status. Here only the
    // unchanged Foundation fields/provenance cross into the real Dart parser
    // and Hive owner lifecycle. A loopback URL cannot authorize an API lease.
    return NativeHTTPRequestLeaseResponse(
      url: snapshot.url,
      statusCode: observed['statusCode'] as int,
      cookieSource: SetCookieSource.foundationCombined,
      setCookieValues: (observed['foundationValues'] as List<dynamic>).cast<String>(),
    );
  }

  for (final name in [
    'single-cookie', 'error-cookie', 'cancel-after-head', 'redirect', 'early-eof',
  ]) {
    test('actual $name fields persist only to the captured Hive owner', () async {
      final observed = observations[name]!;
      final a = await _select(101);
      final service = create();
      final snapshot = await service.prepare(requestID: _requestID());
      final b = await _select(202);
      final received = response(snapshot, observed);
      final receipt = await service.finish(
        requestID: snapshot.requestID,
        leaseID: snapshot.leaseID,
        response: received,
      );
      final cookie = Cookie.fromSetCookieValue(received.setCookieValues.single);
      expect(receipt.outcome, NativeHTTPRequestLeaseOutcome.finished);
      expect(receipt.cookiesSaved, isTrue);
      expect(receipt.cookieCount, 1);
      expect((await _cookies(a, snapshot.url))[cookie.name], cookie.value);
      expect((await _cookies(b, snapshot.url))[cookie.name], isNull);
      expect(persisted, [same(a)]);
      expect(Accounts.account.get('101'), same(a));
      expect(Accounts.get(AccountType.recommend), same(b));
      // Owner identity and actual Hive completion are verified here. Legacy
      // adapter domain/path loss means this is not a restart durability claim.
      if (name == 'cancel-after-head') {
        expect(observed['cancelled'], isTrue);
        expect(observed['transportErrorCode'], -999);
      } else if (name == 'early-eof') {
        expect(observed['transportErrorCode'], isNotNull);
      }
      final replay = await service.finish(
        requestID: snapshot.requestID,
        leaseID: snapshot.leaseID,
        response: received,
      );
      expect(replay.outcome, NativeHTTPRequestLeaseOutcome.consumed);
      expect(replay.cookiesSaved, isFalse);
      expect(persisted.length, 1);
      expect(service.liveLeaseCount, 0);
    });
  }

  for (final name in ['path-ambiguous', 'expires-ambiguous']) {
    test('actual $name combined fields fail before any Cookie or Hive write', () async {
      final a = await _select(101);
      final service = create();
      final snapshot = await service.prepare(requestID: _requestID());
      final before = await _cookies(a, snapshot.url);
      final received = response(snapshot, observations[name]!);
      await expectLater(service.finish(
        requestID: snapshot.requestID,
        leaseID: snapshot.leaseID,
        response: received,
      ), throwsA(isA<NativeHTTPRequestLeaseException>().having(
        (error) => error.code, 'code', 'unsupportedCookieRepresentation',
      )));
      expect(await _cookies(a, snapshot.url), before);
      expect(persisted, isEmpty);
      expect(service.liveLeaseCount, 0);
      final replay = await service.finish(
        requestID: snapshot.requestID,
        leaseID: snapshot.leaseID,
        response: received,
      );
      expect(replay.outcome, NativeHTTPRequestLeaseOutcome.consumed);
      expect(persisted, isEmpty);
    });
  }

  test('actual cancellation before headers abandons without Cookie writes', () async {
    final observed = observations['cancel-before-head']!;
    expect(observed['headCount'], 0);
    expect(observed['cookieSource'], 'none');
    expect(observed['foundationValues'], isEmpty);
    expect(observed['transportErrorCode'], -999);
    final a = await _select(101);
    final service = create();
    final snapshot = await service.prepare(requestID: _requestID());
    final before = await _cookies(a, snapshot.url);
    final receipt = service.abandon(
      requestID: snapshot.requestID, leaseID: snapshot.leaseID,
    );
    expect(receipt.outcome, NativeHTTPRequestLeaseOutcome.abandoned);
    expect(await _cookies(a, snapshot.url), before);
    expect(persisted, isEmpty);
    expect(service.liveLeaseCount, 0);
  });
}
