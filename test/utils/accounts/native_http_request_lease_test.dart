import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_http/native_http_request_lease_bridge.dart';
import 'package:PiliPlus/services/native_http/native_http_request_lease_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/accounts/account_manager/response_cookie_headers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

int _nextID = 0;
String _requestID() =>
    '00000000-0000-4000-8000-${(++_nextID).toRadixString(16).padLeft(12, '0')}';

LoginAccount _account(int mid, {String session = 'initial'}) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'csrf-$mid',
    'SESSDATA': session,
  }),
  'access-$session',
  'refresh-$session',
)..activated = true;

Matcher _leaseError(String code) => isA<NativeHTTPRequestLeaseException>().having(
  (error) => error.code,
  'lease error code',
  code,
);

Future<String?> _cookie(Account account, Uri uri, String name) async {
  final cookies = await account.cookieJar.loadForRequest(uri);
  for (final cookie in cookies) {
    if (cookie.name == name) return cookie.value;
  }
  return null;
}

NativeHTTPRequestLeaseResponse _response(
  NativeHTTPRequestLeaseSnapshot snapshot, {
  int status = 200,
  Iterable<String> cookies = const ['lease_cookie=received; Path=/'],
  SetCookieSource source = SetCookieSource.separatedFields,
  Uri? url,
}) => NativeHTTPRequestLeaseResponse(
  url: url ?? snapshot.url,
  statusCode: status,
  cookieSource: source,
  setCookieValues: cookies,
);

Future<NativeHTTPRequestLeaseReceipt> _finish(
  NativeHTTPRequestLeaseService service,
  NativeHTTPRequestLeaseSnapshot snapshot, {
  int status = 200,
  Iterable<String> cookies = const ['lease_cookie=received; Path=/'],
  SetCookieSource source = SetCookieSource.separatedFields,
  Uri? url,
}) => service.finish(
  requestID: snapshot.requestID,
  leaseID: snapshot.leaseID,
  response: _response(snapshot, status: status, cookies: cookies, source: source, url: url),
);

Map<String, Object?> _prepareCommand() => {
  'requestID': _requestID(), 'purpose': 'searchTrending', 'limit': 10,
};

Map<String, Object?> _finishCommand(NativeHTTPRequestLeaseSnapshot snapshot) => {
  'requestID': snapshot.requestID, 'leaseID': snapshot.leaseID,
  'response': {
    'url': snapshot.url.toString(), 'statusCode': 200,
    'cookieSource': 'separatedFields', 'setCookieValues': ['lease_cookie=received; Path=/'],
  },
};

void main() {
  late AccountTestStorage storage;
  late Dio dio;
  late Duration elapsed;
  final services = <NativeHTTPRequestLeaseService>[];

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });
  setUp(() async {
    await storage.reset();
    elapsed = Duration.zero;
    dio = Dio(BaseOptions(
      baseUrl: HttpString.apiBaseUrl,
      headers: {'accept': 'application/json', 'fixture': 'base'},
    ));
  });
  tearDown(() {
    for (final service in services) {
      service.dispose();
    }
    services.clear();
    dio.close(force: true);
  });
  tearDownAll(() => storage.close());

  NativeHTTPRequestLeaseService create({
    Account Function()? recommendAccount,
    Future<List<Cookie>> Function(Account, Uri)? loadCookies,
    Future<void> Function(Account, Uri, Future<void>)? awaitCookieSave,
    Future<void> Function(Account, Future<void>?)? awaitAccountPersistence,
    Duration ttl = const Duration(minutes: 1),
    int maxLiveLeases = 32,
    int maxTombstones = 128,
  }) {
    final service = NativeHTTPRequestLeaseService(
      options: () => dio.options,
      recommendAccount: recommendAccount,
      loadCookies: loadCookies,
      awaitCookieSave: awaitCookieSave,
      awaitAccountPersistence: awaitAccountPersistence,
      now: () => elapsed,
      ttl: ttl,
      maxLiveLeases: maxLiveLeases,
      maxTombstones: maxTombstones,
      autoExpire: false,
    );
    services.add(service);
    return service;
  }

  Future<LoginAccount> select(int mid, {String session = 'initial'}) async {
    final account = _account(mid, session: session);
    await Accounts.installCredentials(account);
    await Accounts.set(AccountType.recommend, account);
    return account;
  }

  test('snapshot uses recommend, actual Dio headers and immutable copies', () async {
    final main = _account(101, session: 'main');
    await Accounts.installCredentials(main);
    Accounts.selectTemporarily(AccountType.main, main);
    final recommended = await select(202, session: 'recommend');
    final service = create();
    final snapshot = await service.prepare(requestID: _requestID(), limit: 7);
    expect(snapshot.headers['x-bili-mid'], '202');
    expect(snapshot.headers['fixture'], 'base');
    for (final entry in Constants.baseHeaders.entries) {
      expect(snapshot.headers[entry.key], entry.value);
    }
    expect(snapshot.headers['referer'], isNotEmpty);
    expect(snapshot.headers['cookie'], contains('SESSDATA=recommend'));
    expect(snapshot.headers['cookie'], isNot(contains('SESSDATA=main')));
    expect(snapshot.limit, 7);
    expect(snapshot.url.queryParameters['limit'], '7');
    expect(snapshot.generation, Accounts.captureRequest(recommended)!.generation);
    expect(snapshot.executionAllowed, isFalse);
    dio.options.headers['fixture'] = 'later';
    recommended.headers['fixture'] = 'later-account';
    expect(snapshot.headers['fixture'], 'base');
    expect(() => snapshot.headers['fixture'] = 'mutable', throwsUnsupportedError);
  });

  test('Cookie path and duplicate names match real AccountManager request', () async {
    final account = await select(101);
    final service = create();
    final probe = await service.prepare(requestID: _requestID());
    service.abandon(requestID: probe.requestID, leaseID: probe.leaseID);
    await account.cookieJar.saveFromResponse(probe.url, [
      Cookie('duplicate', 'root')..setBiliDomain(),
      Cookie('duplicate', 'search')
        ..setBiliDomain()
        ..path = '/x/v2/search',
      Cookie('excluded', 'private')
        ..setBiliDomain()
        ..path = '/private',
      Cookie('host_only', 'api')..path = '/',
    ]);
    dio.options.headers['cookie'] = 'base_cookie=before';
    final snapshot = await service.prepare(requestID: _requestID());
    final adapter = _CapturingAdapter();
    dio
      ..httpClientAdapter = adapter
      ..interceptors.add(AccountManager());
    await dio.get<dynamic>(
      snapshot.url.toString(),
      options: Options(extra: {'account': account}),
    );
    final nativeCookie = snapshot.headers['cookie']!;
    expect(nativeCookie, adapter.request!.headers['cookie']);
    expect(nativeCookie, contains('base_cookie=before'));
    expect(nativeCookie, contains('host_only=api'));
    expect(nativeCookie, isNot(contains('excluded=private')));
    expect('duplicate='.allMatches(nativeCookie).length, 2);
    expect(nativeCookie.indexOf('duplicate=search'), lessThan(nativeCookie.indexOf('duplicate=root')));
  });

  test('NoAccount never loads credentials or allocates a live lease', () async {
    var loaded = false;
    final service = create(
      recommendAccount: () => const NoAccount(),
      loadCookies: (account, uri) async {
        loaded = true;
        return account.cookieJar.loadForRequest(uri);
      },
    );
    await expectLater(service.prepare(requestID: _requestID()), throwsA(_leaseError('noAccount')));
    expect(loaded, isFalse);
    expect(service.liveLeaseCount, 0);
  });

  for (final change in ['selection', 'cookie revision', 'replacement', 'anonymous reset']) {
    test('prepare rejects $change during actual Cookie load completion', () async {
      final account = change == 'anonymous reset' ? AnonymousAccount() : await select(101);
      final pause = _LoadPause();
      final service = create(loadCookies: pause.call);
      final preparing = service.prepare(requestID: _requestID());
      final rejected = expectLater(preparing, throwsA(_leaseError('snapshotChanged')));
      await pause.entered.future;
      expect(service.pendingLeaseCount, 1);
      switch (change) {
        case 'selection':
          await select(202);
          break;
        case 'cookie revision':
          await account.cookieJar.saveFromResponse(pause.uri!, [Cookie('during_load', 'new')..path = '/']);
          Accounts.notifyCookieMutation(account);
          break;
        case 'replacement':
          await Accounts.installCredentials(_account(101, session: 'new'));
          break;
        case 'anonymous reset':
          await account.delete();
          break;
      }
      pause.release.complete();
      await rejected;
      expect(service.liveLeaseCount, 0);
    });
  }

  test('abandon pending prepare prevents late callback from reinstalling lease', () async {
    await select(101);
    final pause = _LoadPause();
    final service = create(loadCookies: pause.call);
    final requestID = _requestID();
    final preparing = service.prepare(requestID: requestID);
    final rejected = expectLater(preparing, throwsA(_leaseError('abandoned')));
    await pause.entered.future;
    expect(service.abandon(requestID: requestID).outcome.name, 'abandoned');
    expect(service.liveLeaseCount, 0);
    pause.release.complete();
    await rejected;
    expect(service.liveLeaseCount, 0);
    await expectLater(service.prepare(requestID: requestID), throwsA(_leaseError('consumed')));
  });

  test('unknown abandon leaves bounded tombstone for late prepare command', () async {
    final service = create(maxTombstones: 2);
    final requestID = _requestID();
    expect(service.abandon(requestID: requestID).outcome.name, 'unknown');
    await expectLater(service.prepare(requestID: requestID), throwsA(_leaseError('consumed')));
    for (var index = 0; index < 5; index++) {
      service.abandon(requestID: _requestID());
      expect(service.tombstoneCount, lessThanOrEqualTo(2));
    }
    expect(service.liveLeaseCount, 0);
  });

  test('duplicate prepare cannot start another load for a pending requestID', () async {
    await select(101);
    final pause = _LoadPause();
    final service = create(loadCookies: pause.call);
    final requestID = _requestID();
    final first = service.prepare(requestID: requestID);
    await pause.entered.future;
    await expectLater(service.prepare(requestID: requestID), throwsA(_leaseError('consumed')));
    expect(pause.calls, 1);
    pause.release.complete();
    final snapshot = await first;
    expect(service.liveLeaseCount, 1);
    expect(snapshot.requestID, requestID);
  });

  test('finish and abandon share one terminal claim', () async {
    final account = await select(101);
    final service = create();
    final empty = await service.prepare(requestID: _requestID());
    final beforeEmpty = Accounts.requestRevision;
    final emptyReceipt = await _finish(service, empty, status: 403, cookies: const []);
    expect(emptyReceipt.outcome.name, 'finished');
    expect(emptyReceipt.cookiesSaved, isFalse);
    expect(emptyReceipt.cookieCount, 0);
    expect(Accounts.requestRevision, beforeEmpty);
    expect((await _finish(service, empty)).outcome.name, 'consumed');
    final snapshot = await service.prepare(requestID: _requestID());
    expect((await _finish(service, snapshot)).cookiesSaved, isTrue);
    final revision = Accounts.requestRevision;
    expect((await _finish(service, snapshot, cookies: const ['lease_cookie=twice; Path=/'])).outcome.name, 'consumed');
    expect(service.abandon(requestID: snapshot.requestID, leaseID: snapshot.leaseID).outcome.name, 'consumed');
    expect(await _cookie(account, snapshot.url, 'lease_cookie'), 'received');
    expect(Accounts.requestRevision, revision);
    expect(service.liveLeaseCount, 0);
  });

  test('abandon prepared lease suppresses all response Cookie writes', () async {
    final account = await select(101);
    final service = create();
    final snapshot = await service.prepare(requestID: _requestID());
    expect(service.abandon(requestID: snapshot.requestID, leaseID: snapshot.leaseID).outcome.name, 'abandoned');
    expect((await _finish(service, snapshot)).cookiesSaved, isFalse);
    expect(await _cookie(account, snapshot.url, 'lease_cookie'), isNull);
  });

  test('wrong lease token cannot consume the valid request-token pair', () async {
    final account = await select(101);
    final service = create();
    final snapshot = await service.prepare(requestID: _requestID());
    await expectLater(service.finish(
      requestID: snapshot.requestID,
      leaseID: _requestID(),
      response: _response(snapshot),
    ), throwsA(_leaseError('leaseMismatch')));
    expect(() => service.abandon(requestID: snapshot.requestID, leaseID: _requestID()),
      throwsA(_leaseError('leaseMismatch')));
    expect(service.liveLeaseCount, 1);
    expect(await _cookie(account, snapshot.url, 'lease_cookie'), isNull);
    expect((await _finish(service, snapshot)).cookiesSaved, isTrue);
  });

  test('monotonic TTL expires prepared leases before Cookie persistence', () async {
    final account = await select(101);
    final service = create(ttl: const Duration(seconds: 5));
    final snapshot = await service.prepare(requestID: _requestID());
    elapsed = const Duration(seconds: 5);
    service.pruneExpired();
    expect(service.liveLeaseCount, 0);
    expect((await _finish(service, snapshot)).cookiesSaved, isFalse);
    expect(await _cookie(account, snapshot.url, 'lease_cookie'), isNull);
    expect((await service.prepare(requestID: _requestID())).executionAllowed, isFalse);

    final pause = _LoadPause();
    final pendingService = create(ttl: const Duration(seconds: 5), loadCookies: pause.call);
    final preparing = pendingService.prepare(requestID: _requestID());
    final rejected = expectLater(preparing, throwsA(_leaseError('expired')));
    await pause.entered.future;
    elapsed = const Duration(seconds: 10);
    pendingService.pruneExpired();
    expect(pendingService.liveLeaseCount, 0);
    pause.release.complete();
    await rejected;
    expect(pendingService.liveLeaseCount, 0);
  });

  test('live capacity is bounded and released by a terminal claim', () async {
    final service = create(maxLiveLeases: 2);
    final first = await service.prepare(requestID: _requestID());
    await service.prepare(requestID: _requestID());
    await expectLater(service.prepare(requestID: _requestID()), throwsA(_leaseError('capacity')));
    expect(service.liveLeaseCount, 2);
    service.abandon(requestID: first.requestID, leaseID: first.leaseID);
    await service.prepare(requestID: _requestID());
    expect(service.liveLeaseCount, 2);
  });

  test('dispose synchronously closes pending prepare and late completion', () async {
    await select(101);
    final pause = _LoadPause();
    final service = create(loadCookies: pause.call);
    final preparing = service.prepare(requestID: _requestID());
    final rejected = expectLater(preparing, throwsA(_leaseError('closed')));
    await pause.entered.future;
    service.dispose();
    expect(service.liveLeaseCount, 0);
    pause.release.complete();
    await rejected;
    await expectLater(service.prepare(requestID: _requestID()), throwsA(_leaseError('closed')));
  });

  for (final status in [200, 403, 302]) {
    test('HTTP $status Cookie writes remain with valid A after selecting B', () async {
      final a = await select(101, session: 'a');
      final service = create();
      final snapshot = await service.prepare(requestID: _requestID());
      final b = await select(202, session: 'b');
      final receipt = await _finish(service, snapshot, status: status);
      expect(receipt.outcome.name, 'finished');
      expect(receipt.cookiesSaved, isTrue);
      expect(receipt.cookieCount, 1);
      expect(await _cookie(a, snapshot.url, 'lease_cookie'), 'received');
      expect(await _cookie(b, snapshot.url, 'lease_cookie'), isNull);
      expect(Accounts.account.get('101'), same(a));
      expect(Accounts.get(AccountType.recommend), same(b));
    });
  }

  test('A to B to A and concurrent Cookie revisions do not revoke prepared A', () async {
    final a = await select(101);
    final service = create();
    final first = await service.prepare(requestID: _requestID());
    final second = await service.prepare(requestID: _requestID());
    await select(202);
    await Accounts.set(AccountType.recommend, a);
    expect((await _finish(service, first, cookies: const ['first=one; Path=/'])).cookiesSaved, isTrue);
    expect((await _finish(service, second, cookies: const ['second=two; Path=/'])).cookiesSaved, isTrue);
    expect(await _cookie(a, first.url, 'first'), 'one');
    expect(await _cookie(a, first.url, 'second'), 'two');
  });

  for (final revoke in ['same MID replacement', 'delete', 'clear', 'anonymous reset']) {
    test('$revoke blocks prepared old generation without any Cookie write', () async {
      final account = revoke == 'anonymous reset' ? AnonymousAccount() : await select(101);
      final service = create();
      final snapshot = await service.prepare(requestID: _requestID());
      switch (revoke) {
        case 'same MID replacement':
          await Accounts.installCredentials(_account(101, session: 'replacement'));
          break;
        case 'delete':
          await account.delete();
          break;
        case 'clear':
          await select(202);
          await Accounts.clear();
          break;
        case 'anonymous reset':
          await account.delete();
          break;
      }
      final receipt = await _finish(service, snapshot);
      expect(receipt.outcome.name, 'revoked');
      expect(receipt.cookiesSaved, isFalse);
      expect(await _cookie(account, snapshot.url, 'lease_cookie'), isNull);
      if (revoke == 'same MID replacement') {
        final replacement = Accounts.account.get('101')!;
        expect(await _cookie(replacement, snapshot.url, 'SESSDATA'), 'replacement');
        expect(await _cookie(replacement, snapshot.url, 'lease_cookie'), isNull);
      }
    });
  }

  test('malformed Cookie batch consumes lease with zero partial writes', () async {
    final account = await select(101);
    final service = create();
    final snapshot = await service.prepare(requestID: _requestID());
    final revision = Accounts.requestRevision;
    await expectLater(
      _finish(service, snapshot, cookies: const ['lease_cookie=valid; Path=/', 'bad=value; Max-Age=nope']),
      throwsA(_leaseError('invalidCookieHeaders')),
    );
    expect(await _cookie(account, snapshot.url, 'lease_cookie'), isNull);
    expect(Accounts.requestRevision, revision);
    expect((await _finish(service, snapshot)).outcome.name, 'consumed');
  });

  test('response origin, path and full query must match prepared URL', () async {
    final account = await select(101);
    final service = create();
    for (final component in ['host', 'path', 'query']) {
      final snapshot = await service.prepare(requestID: _requestID());
      final wrongURL = switch (component) {
        'host' => snapshot.url.replace(host: 'passport.bilibili.com'),
        'path' => snapshot.url.replace(path: '/other'),
        _ => snapshot.url.replace(query: '${snapshot.url.query}&unexpected=1'),
      };
      await expectLater(_finish(service, snapshot, url: wrongURL), throwsA(_leaseError('invalidResponse')));
      expect((await _finish(service, snapshot)).outcome.name, 'consumed');
      expect(await _cookie(account, snapshot.url, 'lease_cookie'), isNull);
    }
  });

  test('Foundation ambiguous field refuses whole batch instead of speculating', () async {
    final account = await select(101);
    final service = create();
    final snapshot = await service.prepare(requestID: _requestID());
    await expectLater(
      _finish(service, snapshot, source: SetCookieSource.foundationCombined,
        cookies: const ['lease_cookie=valid', 'a=1; Path=/x, b=2']),
      throwsA(_leaseError('unsupportedCookieRepresentation')),
    );
    expect(await _cookie(account, snapshot.url, 'lease_cookie'), isNull);
    expect(await _cookie(account, snapshot.url, 'b'), isNull);
  });

  test('TTL during actual save completion cannot reopen finish gate', () async {
    final account = await select(101);
    final pause = _CompletionPause();
    final service = create(ttl: const Duration(seconds: 1), awaitCookieSave: pause.save);
    final snapshot = await service.prepare(requestID: _requestID());
    final finishing = _finish(service, snapshot);
    await pause.entered.future;
    // This is pinned CookieJar's real, already executed synchronous mutation.
    expect(await _cookie(account, snapshot.url, 'lease_cookie'), 'received');
    elapsed = const Duration(minutes: 5);
    service.pruneExpired();
    expect(service.finishingLeaseCount, 1);
    expect((await _finish(service, snapshot, cookies: const ['lease_cookie=duplicate; Path=/'])).outcome.name, 'consumed');
    expect(service.abandon(requestID: snapshot.requestID, leaseID: snapshot.leaseID).outcome.name, 'consumed');
    await expectLater(service.prepare(requestID: snapshot.requestID), throwsA(_leaseError('consumed')));
    expect(pause.calls, 1);
    pause.release.complete();
    expect((await finishing).outcome.name, 'finished');
    expect(service.finishingLeaseCount, 0);
    expect(await _cookie(account, snapshot.url, 'lease_cookie'), 'received');
  });

  test('same MID replacement during real save await cannot persist old owner', () async {
    final old = await select(101, session: 'old');
    final pause = _CompletionPause();
    final service = create(awaitCookieSave: pause.save);
    final snapshot = await service.prepare(requestID: _requestID());
    final finishing = _finish(service, snapshot);
    await pause.entered.future;
    expect(await _cookie(old, snapshot.url, 'lease_cookie'), 'received');
    final replacement = _account(101, session: 'replacement');
    await Accounts.installCredentials(replacement);
    pause.release.complete();
    final receipt = await finishing;
    expect(receipt.outcome.name, 'revoked');
    expect(receipt.cookiesSaved, isTrue);
    expect(receipt.cookieCount, 1);
    expect(Accounts.account.get('101'), same(replacement));
    expect(await _cookie(replacement, snapshot.url, 'SESSDATA'), 'replacement');
    expect(await _cookie(replacement, snapshot.url, 'lease_cookie'), isNull);
    expect((await _finish(service, snapshot)).cookiesSaved, isFalse);
  });

  test('dispose during real Hive completion never revives claimed request', () async {
    await select(101);
    final pause = _CompletionPause();
    final service = create(awaitAccountPersistence: pause.persist);
    final snapshot = await service.prepare(requestID: _requestID());
    final finishing = _finish(service, snapshot);
    await pause.entered.future;
    service.dispose();
    expect(service.liveLeaseCount, 0);
    expect((await _finish(service, snapshot)).cookiesSaved, isFalse);
    await expectLater(service.prepare(requestID: snapshot.requestID), throwsA(_leaseError('closed')));
    pause.release.complete();
    final receipt = await finishing;
    expect(receipt.outcome.name, 'closed');
    expect(receipt.cookiesSaved, isTrue);
    expect(receipt.cookieCount, 1);
    expect(service.liveLeaseCount, 0);
    expect(pause.calls, 1);
  });

  for (final completion in ['Cookie save', 'Hive persistence']) {
    test('$completion completion failure consumes gate after real mutation', () async {
      final account = await select(101);
      Future<void> fail(Future<void>? realCompletion) async {
        await realCompletion;
        throw StateError('injected completion failure');
      }
      final service = create(
        awaitCookieSave: completion == 'Cookie save' ? (account, uri, saving) => fail(saving) : null,
        awaitAccountPersistence: completion == 'Hive persistence' ? (account, saving) => fail(saving) : null,
      );
      final snapshot = await service.prepare(requestID: _requestID());
      await expectLater(_finish(service, snapshot), throwsA(_leaseError('persistenceFailed')));
      expect(await _cookie(account, snapshot.url, 'lease_cookie'), 'received');
      final revision = Accounts.requestRevision;
      expect(service.liveLeaseCount, 0);
      expect(service.finishingLeaseCount, 0);
      expect((await _finish(service, snapshot, cookies: const ['lease_cookie=duplicate; Path=/'])).outcome.name, 'consumed');
      expect(Accounts.requestRevision, revision);
      expect(await _cookie(account, snapshot.url, 'lease_cookie'), 'received');
    });
  }

  test('default timer automatically sweeps pending lease without prune', () async {
    final pause = _LoadPause();
    final service = NativeHTTPRequestLeaseService(
      options: () => dio.options, loadCookies: pause.call, now: () => elapsed,
      ttl: const Duration(milliseconds: 100),
    );
    services.add(service);
    final preparing = service.prepare(requestID: _requestID());
    final rejected = expectLater(preparing, throwsA(_leaseError('expired')));
    await pause.entered.future;
    elapsed = const Duration(milliseconds: 100);
    final deadline = Stopwatch()..start();
    while (service.liveLeaseCount != 0 && deadline.elapsed < const Duration(seconds: 3)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(service.liveLeaseCount, 0);
    pause.release.complete();
    await rejected;
    expect(service.liveLeaseCount, 0);
  });

  test('prepare codec rejects invalid shapes, scalar types and purpose', () async {
    final service = create();
    final bridge = NativeHTTPRequestLeaseBridge(service: service);
    for (final arguments in [
      null, [], {1: 'non-string key'},
      {..._prepareCommand(), 'requestID': 'invalid'},
      {..._prepareCommand(), 'limit': 10.0},
      {..._prepareCommand(), 'limit': true},
      {..._prepareCommand(), 'limit': 31},
      {..._prepareCommand(), 'purpose': 'video'},
    ]) {
      final result = await bridge.handle('prepareNativeHTTPRequest', arguments);
      expect(result['state'], 'error');
      expect(result['code'], 'invalidArguments');
      expect(result['executionAllowed'], isFalse);
      expect(service.liveLeaseCount, 0);
    }
  });

  test('prepare codec cannot accept caller URL, MID, headers or execution flag', () async {
    final service = create();
    final bridge = NativeHTTPRequestLeaseBridge(service: service);
    for (final injected in ['url', 'mid', 'headers', 'executionAllowed']) {
      final result = await bridge.handle('prepareNativeHTTPRequest', {..._prepareCommand(), injected: 'injected'});
      expect(result['code'], 'invalidArguments');
      expect(result['executionAllowed'], isFalse);
      expect(service.liveLeaseCount, 0);
    }
  });

  test('finish codec validates complete response before claiming valid lease', () async {
    final account = await select(101);
    final service = create();
    final bridge = NativeHTTPRequestLeaseBridge(service: service);
    final snapshot = await service.prepare(requestID: _requestID());
    final command = _finishCommand(snapshot);
    final response = Map<String, Object?>.from(command['response']! as Map);
    for (final invalid in [
      {...response, 'statusCode': 200.0}, {...response, 'url': 1},
      {...response, 'setCookieValues': ['valid=one', 1]},
      {...response, 'location': 'https://passport.bilibili.com'},
      {...response, 'cookieSource': 'unproven'},
    ]) {
      final result = await bridge.handle('finishNativeHTTPRequest', {...command, 'response': invalid});
      expect(result['code'], 'invalidArguments');
      expect(result['executionAllowed'], isFalse);
      expect(service.liveLeaseCount, 1);
      expect(await _cookie(account, snapshot.url, 'lease_cookie'), isNull);
    }
    expect(service.abandon(requestID: snapshot.requestID, leaseID: snapshot.leaseID).outcome.name, 'abandoned');
  });

  test('codec preserves Foundation provenance and closes ambiguous persistence', () async {
    final account = await select(101);
    final service = create();
    final bridge = NativeHTTPRequestLeaseBridge(service: service);
    final snapshot = await service.prepare(requestID: _requestID());
    final result = await bridge.handle('finishNativeHTTPRequest', {
      'requestID': snapshot.requestID, 'leaseID': snapshot.leaseID,
      'response': {
        'url': snapshot.url.toString(), 'statusCode': 403,
        'cookieSource': 'foundationCombined', 'setCookieValues': ['lease_cookie=one; Path=/x, b=2'],
      },
    });
    expect(result['code'], 'unsupportedCookieRepresentation');
    expect(result['executionAllowed'], isFalse);
    expect(service.liveLeaseCount, 0);
    expect(await _cookie(account, snapshot.url, 'lease_cookie'), isNull);
  });

  test('normal bridge roundtrip never enables execution and dispose closes it', () async {
    final service = create();
    final bridge = NativeHTTPRequestLeaseBridge(service: service);
    final command = _prepareCommand();
    final prepared = await bridge.handle('prepareNativeHTTPRequest', command);
    expect(prepared['state'], 'prepared');
    expect(prepared['executionAllowed'], isFalse);
    expect(prepared['requestID'], command['requestID']);
    expect(prepared['method'], 'GET');
    expect(() => (prepared['headers']! as Map)['injected'] = 'later', throwsUnsupportedError);
    final response = await bridge.handle('finishNativeHTTPRequest', {
      'requestID': prepared['requestID'], 'leaseID': prepared['leaseID'],
      'response': {'url': prepared['url'], 'statusCode': 200,
        'cookieSource': 'separatedFields', 'setCookieValues': <String>[]},
    });
    expect(response['state'], 'finished');
    expect(response['cookiesSaved'], isFalse);
    expect(response['executionAllowed'], isFalse);
    bridge.dispose();
    final closed = await bridge.handle('prepareNativeHTTPRequest', _prepareCommand());
    expect(closed['code'], 'closed');
    expect(closed['executionAllowed'], isFalse);
  });
}

class _LoadPause {
  int calls = 0;
  Uri? uri;
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<List<Cookie>> call(Account account, Uri requestURL) async {
    calls++;
    uri = requestURL;
    final cookies = await account.cookieJar.loadForRequest(requestURL);
    entered.complete();
    await release.future;
    return cookies;
  }
}

class _CompletionPause {
  int calls = 0;
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> save(Account account, Uri uri, Future<void> saving) => _wait(saving);
  Future<void> persist(Account account, Future<void>? persisting) => _wait(persisting);

  Future<void> _wait(Future<void>? completion) async {
    await completion;
    calls++;
    entered.complete();
    await release.future;
  }
}

class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    request = options;
    return Future.value(ResponseBody.fromString('{}', 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    }));
  }

  @override
  void close({bool force = false}) {}
}
