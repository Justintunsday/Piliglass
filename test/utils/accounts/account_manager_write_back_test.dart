import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/native_accounts/account_write_back_coordinator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

final _origin = Uri.parse('https://www.bilibili.com/github/write-back-fixture');
final _redirect = Uri.parse(
  'https://passport.bilibili.com/github/write-back-fixture',
);

/// Real jar whose returned Future is gated while the mutation itself already
/// happened synchronously, matching the pinned CookieJar contract.
final class _GatedJar extends DefaultCookieJar {
  _GatedJar(int mid) : super(ignoreExpires: true) {
    final seed = BiliCookieJar.fromJson({
      'DedeUserID': '$mid',
      'bili_jct': 'csrf-$mid',
      'SESSDATA': 'session-$mid',
    });
    domainCookies.addAll(seed.domainCookies);
    hostCookies.addAll(seed.hostCookies);
  }

  final saveStarted = Completer<void>();
  Completer<void>? _pending;
  Completer<void>? _held;

  void holdNextSave() => _pending = Completer<void>();

  void releaseSave() {
    final held = _held;
    _held = null;
    held?.complete();
  }

  @override
  Future<void> saveFromResponse(Uri uri, List<Cookie> cookies) {
    final real = super.saveFromResponse(uri, cookies);
    final gate = _pending;
    if (gate == null) return real;
    _pending = null;
    _held = gate;
    if (!saveStarted.isCompleted) saveStarted.complete();
    return _join(real, gate.future);
  }

  static Future<void> _join(Future<void> real, Future<void> gate) async {
    await real;
    await gate;
  }
}

/// Real LoginAccount whose persistence Future is gated at the Hive await.
final class _GatedAccount extends LoginAccount {
  _GatedAccount(this.gatedJar)
      : super(
          gatedJar,
          'synthetic-write-back-access',
          'synthetic-write-back-refresh',
        );

  final _GatedJar gatedJar;
  final persistenceStarted = Completer<void>();
  Completer<void>? _pendingPersistence;
  Completer<void>? _heldPersistence;

  void holdNextPersistence() => _pendingPersistence = Completer<void>();

  void releasePersistence() {
    final held = _heldPersistence;
    _heldPersistence = null;
    held?.complete();
  }

  @override
  Future<void>? onChange() {
    final real = super.onChange();
    final gate = _pendingPersistence;
    if (gate == null) return real;
    _pendingPersistence = null;
    _heldPersistence = gate;
    if (!persistenceStarted.isCompleted) persistenceStarted.complete();
    return _join(real, gate.future);
  }

  static Future<void> _join(Future<void>? real, Future<void> gate) async {
    if (real != null) await real;
    await gate;
  }
}

LoginAccount _plainAccount(int mid) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'csrf-successor',
    'SESSDATA': 'session-successor',
  }),
  'access-successor',
  'refresh-successor',
)..activated = true;

Future<String?> _cookie(Account account, String name, {Uri? uri}) async {
  final cookies = await account.cookieJar.loadForRequest(uri ?? _origin);
  for (final cookie in cookies) {
    if (cookie.name == name) return cookie.value;
  }
  return null;
}

void main() {
  late AccountTestStorage storage;
  late Dio dio;
  late _ControlledAdapter adapter;
  late AccountWriteBackCoordinator coordinator;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });

  setUp(() async {
    await storage.reset();
    coordinator = AccountWriteBackCoordinator();
    adapter = _ControlledAdapter();
    dio = Dio(
      BaseOptions(responseType: ResponseType.plain, followRedirects: false),
    )
      ..httpClientAdapter = adapter
      ..interceptors.add(AccountManager(writeBackCoordinator: coordinator));
  });

  tearDown(() => dio.close(force: true));
  tearDownAll(() => storage.close());

  Future<Response<String>> send(Account account) => dio.get<String>(
    _origin.toString(),
    options: Options(extra: {'account': account}),
  );

  test('freeze during the cookie await drains only after the admitted chain finishes', () async {
    final account = _GatedAccount(_GatedJar(920001));
    await Accounts.installCredentials(account);
    account.gatedJar.holdNextSave();
    final response = send(account);
    final request = await adapter.nextRequest();
    final result = expectLater(response, completes);
    request.complete(
      status: 200,
      cookies: ['first_write=one; Domain=.bilibili.com; Path=/'],
    );
    await account.gatedJar.saveStarted.future;
    expect(coordinator.liveOperationCount, 1);
    var drained = false;
    final drain = coordinator.freeze()
      ..then((_) => drained = true);
    await Future<void>.value();
    expect(drained, false);
    expect(coordinator.tryAdmit(), isNull);
    account.gatedJar.releaseSave();
    await result;
    await drain;
    expect(drained, true);
    expect(await _cookie(account, 'first_write'), 'one');
    expect(coordinator.liveOperationCount, 0);
  });

  test('freeze during Hive persistence drains only after the admitted chain finishes', () async {
    final account = _GatedAccount(_GatedJar(920002));
    await Accounts.installCredentials(account);
    account.holdNextPersistence();
    final response = send(account);
    final request = await adapter.nextRequest();
    final result = expectLater(response, completes);
    request.complete(
      status: 200,
      cookies: ['second_write=one; Domain=.bilibili.com; Path=/'],
    );
    await account.persistenceStarted.future;
    expect(coordinator.liveOperationCount, 1);
    var drained = false;
    final drain = coordinator.freeze()
      ..then((_) => drained = true);
    await Future<void>.value();
    expect(drained, false);
    account.releasePersistence();
    await result;
    await drain;
    expect(drained, true);
    expect(Accounts.account.get('920002'), same(account));
    expect(coordinator.liveOperationCount, 0);
  });

  test('frozen admission rejects a new response write-back with zero writes', () async {
    final account = _GatedAccount(_GatedJar(920003));
    await Accounts.installCredentials(account);
    await coordinator.freeze();
    final revision = Accounts.requestRevision;
    final response = send(account);
    final request = await adapter.nextRequest();
    request.complete(
      status: 200,
      cookies: ['blocked=one; Domain=.bilibili.com; Path=/'],
    );
    await expectLater(response, completes);
    expect(await _cookie(account, 'blocked'), isNull);
    expect(Accounts.requestRevision, revision);
    expect(coordinator.admittedCount, 0);
  });

  test('one admission covers the original each redirect save and persistence', () async {
    final account = _GatedAccount(_GatedJar(920004));
    await Accounts.installCredentials(account);
    account.gatedJar.holdNextSave();
    final response = send(account);
    final request = await adapter.nextRequest();
    final result = expectLater(
      response,
      throwsA(isA<DioException>().having(
        (error) => error.response?.statusCode,
        'status code',
        302,
      )),
    );
    request.complete(
      status: 302,
      cookies: ['redirect_cookie=from-original; Path=/'],
      location: _redirect,
    );
    await account.gatedJar.saveStarted.future;
    expect(coordinator.liveOperationCount, 1);
    var drained = false;
    final drain = coordinator.freeze()
      ..then((_) => drained = true);
    await Future<void>.value();
    expect(drained, false);
    account.gatedJar.releaseSave();
    await result;
    await drain;
    expect(drained, true);
    expect(await _cookie(account, 'redirect_cookie'), 'from-original');
    expect(
      await _cookie(account, 'redirect_cookie', uri: _redirect),
      'from-original',
    );
    expect(coordinator.liveOperationCount, 0);
  });

  test('owner checks still stop an admitted chain after a same-MID successor', () async {
    final account = _GatedAccount(_GatedJar(920005));
    await Accounts.installCredentials(account);
    account.gatedJar.holdNextSave();
    final response = send(account);
    final request = await adapter.nextRequest();
    final result = expectLater(response, completes);
    request.complete(
      status: 200,
      cookies: ['predecessor_write=one; Domain=.bilibili.com; Path=/'],
    );
    await account.gatedJar.saveStarted.future;
    final drain = coordinator.freeze();
    final successor = _plainAccount(920005);
    await Accounts.installCredentials(successor);
    account.gatedJar.releaseSave();
    await result;
    await drain;
    expect(coordinator.liveOperationCount, 0);
    expect(await _cookie(successor, 'predecessor_write'), isNull);
    expect(await _cookie(successor, 'SESSDATA'), 'session-successor');
    expect(Accounts.account.get('920005'), same(successor));
  });
}

class _PendingRequest {
  _PendingRequest(this.options);

  final RequestOptions options;
  final Completer<ResponseBody> response = Completer<ResponseBody>();

  void complete({
    required int status,
    required List<String> cookies,
    Uri? location,
  }) {
    response.complete(
      ResponseBody.fromString(
        '{}',
        status,
        isRedirect: status >= 300 && status < 400,
        headers: {
          Headers.contentTypeHeader: ['text/plain'],
          HttpHeaders.setCookieHeader: cookies,
          if (location != null)
            HttpHeaders.locationHeader: [location.toString()],
        },
      ),
    );
  }
}

class _ControlledAdapter implements HttpClientAdapter {
  int fetchCount = 0;
  final Queue<_PendingRequest> _requests = Queue<_PendingRequest>();
  final Queue<Completer<_PendingRequest>> _waiters =
      Queue<Completer<_PendingRequest>>();

  Future<_PendingRequest> nextRequest() {
    if (_requests.isNotEmpty) return Future.value(_requests.removeFirst());
    final waiter = Completer<_PendingRequest>();
    _waiters.add(waiter);
    return waiter.future;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    fetchCount++;
    final request = _PendingRequest(options);
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(request);
    } else {
      _requests.add(request);
    }
    return request.response.future;
  }

  @override
  void close({bool force = false}) {}
}
