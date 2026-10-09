import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/native_accounts/account_write_back_coordinator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_adapter.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'account_credential_reader_fixtures.dart';
import 'account_test_storage.dart';

final _origin = Uri.parse('https://www.bilibili.com/github/write-back-fixture');
final _redirect = Uri.parse(
  'https://passport.bilibili.com/github/write-back-fixture',
);
final _secondRedirect = Uri.parse(
  'https://passport2.bilibili.com/github/write-back-fixture',
);

void _seedJar(DefaultCookieJar jar, int mid) {
  final seed = BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'csrf-$mid',
    'SESSDATA': 'session-$mid',
  });
  jar.domainCookies.addAll(seed.domainCookies);
  jar.hostCookies.addAll(seed.hostCookies);
}

final class _SaveHold {
  final gate = Completer<void>();
  final started = Completer<void>();
}

final class _PersistenceHold {
  final gate = Completer<void>();
  final started = Completer<void>();
}

/// Real jar whose returned Future is gated per call while the mutation itself
/// already happened synchronously, matching the pinned CookieJar contract.
final class _GatedJar extends DefaultCookieJar {
  _GatedJar(int mid) : super(ignoreExpires: true) {
    _seedJar(this, mid);
  }

  final List<_SaveHold> _pending = [];
  _SaveHold? _active;
  int saveCount = 0;

  _SaveHold holdNextSave() {
    final hold = _SaveHold();
    _pending.add(hold);
    return hold;
  }

  void releaseSave(_SaveHold hold) {
    if (identical(_active, hold)) {
      _active = null;
      hold.gate.complete();
    }
  }

  @override
  Future<void> saveFromResponse(Uri uri, List<Cookie> cookies) {
    final real = super.saveFromResponse(uri, cookies);
    saveCount++;
    if (_pending.isEmpty) return real;
    final hold = _pending.removeAt(0);
    _active = hold;
    hold.started.complete();
    return _join(real, hold.gate.future);
  }

  static Future<void> _join(Future<void> real, Future<void> gate) async {
    await real;
    await gate;
  }
}

/// Real LoginAccount whose persistence Future is gated per call.
final class _GatedAccount extends LoginAccount {
  _GatedAccount(this.gatedJar)
      : super(
          gatedJar,
          'synthetic-write-back-access',
          'synthetic-write-back-refresh',
        );

  final _GatedJar gatedJar;
  final List<_PersistenceHold> _pending = [];
  _PersistenceHold? _active;

  _PersistenceHold holdNextPersistence() {
    final hold = _PersistenceHold();
    _pending.add(hold);
    return hold;
  }

  void releasePersistence(_PersistenceHold hold) {
    if (identical(_active, hold)) {
      _active = null;
      hold.gate.complete();
    }
  }

  @override
  Future<void>? onChange() {
    final real = super.onChange();
    if (_pending.isEmpty) return real;
    final hold = _pending.removeAt(0);
    _active = hold;
    hold.started.complete();
    return _join(real, hold.gate.future);
  }

  static Future<void> _join(Future<void>? real, Future<void> gate) async {
    if (real != null) await real;
    await gate;
  }
}

/// Real jar that applies the mutation and then reports an error.
final class _ThrowingJar extends DefaultCookieJar {
  _ThrowingJar(int mid) : super(ignoreExpires: true) {
    _seedJar(this, mid);
  }

  @override
  Future<void> saveFromResponse(Uri uri, List<Cookie> cookies) async {
    await super.saveFromResponse(uri, cookies);
    throw StateError('synthetic save failure after real mutation');
  }
}

LoginAccount _loginAccount(int mid, {String session = 'reader'}) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'csrf-$mid',
    'SESSDATA': session,
  }),
  'access-$session',
  'refresh-$session',
)..activated = true;

LoginAccount _plainAccount(int mid) => _loginAccount(mid, session: 'successor');

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
    final hold = account.gatedJar.holdNextSave();
    final response = send(account);
    final request = await adapter.nextRequest();
    final result = expectLater(response, completes);
    request.complete(
      status: 200,
      cookies: ['first_write=one; Domain=.bilibili.com; Path=/'],
    );
    await hold.started.future;
    expect(coordinator.liveOperationCount, 1);
    var drained = false;
    final drain = coordinator.freeze()
      ..then((_) => drained = true);
    await Future<void>.value();
    expect(drained, false);
    expect(coordinator.tryAdmit(), isNull);
    account.gatedJar.releaseSave(hold);
    await result;
    await drain;
    expect(drained, true);
    expect(await _cookie(account, 'first_write'), 'one');
    expect(coordinator.liveOperationCount, 0);
  });

  test('freeze during Hive persistence drains only after the admitted chain finishes', () async {
    final account = _GatedAccount(_GatedJar(920002));
    await Accounts.installCredentials(account);
    final hold = account.holdNextPersistence();
    final response = send(account);
    final request = await adapter.nextRequest();
    final result = expectLater(response, completes);
    request.complete(
      status: 200,
      cookies: ['second_write=one; Domain=.bilibili.com; Path=/'],
    );
    await hold.started.future;
    expect(coordinator.liveOperationCount, 1);
    var drained = false;
    final drain = coordinator.freeze()
      ..then((_) => drained = true);
    await Future<void>.value();
    expect(drained, false);
    account.releasePersistence(hold);
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

  test('each redirect save and the final persistence drain only after release', () async {
    final account = _GatedAccount(_GatedJar(920004));
    await Accounts.installCredentials(account);
    final original = account.gatedJar.holdNextSave();
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
      locations: [_redirect, _secondRedirect],
    );
    await original.started.future;
    var drained = false;
    final drain = coordinator.freeze()
      ..then((_) => drained = true);
    await Future<void>.value();
    expect(drained, false);

    final first = account.gatedJar.holdNextSave();
    account.gatedJar.releaseSave(original);
    await first.started.future;
    await Future<void>.value();
    expect(drained, false);

    final second = account.gatedJar.holdNextSave();
    account.gatedJar.releaseSave(first);
    await second.started.future;
    await Future<void>.value();
    expect(drained, false);

    final persistence = account.holdNextPersistence();
    account.gatedJar.releaseSave(second);
    await persistence.started.future;
    await Future<void>.value();
    expect(drained, false);

    account.releasePersistence(persistence);
    await result;
    await drain;
    expect(drained, true);
    expect(account.gatedJar.saveCount, 3);
    expect(await _cookie(account, 'redirect_cookie'), 'from-original');
    expect(await _cookie(account, 'redirect_cookie', uri: _redirect), 'from-original');
    expect(
      await _cookie(account, 'redirect_cookie', uri: _secondRedirect),
      'from-original',
    );
    expect(coordinator.liveOperationCount, 0);
  });

  test('owner checks still stop an admitted chain after a same-MID successor', () async {
    final account = _GatedAccount(_GatedJar(920005));
    await Accounts.installCredentials(account);
    final hold = account.gatedJar.holdNextSave();
    final response = send(account);
    final request = await adapter.nextRequest();
    final result = expectLater(response, completes);
    request.complete(
      status: 200,
      cookies: ['predecessor_write=one; Domain=.bilibili.com; Path=/'],
    );
    await hold.started.future;
    final drain = coordinator.freeze();
    final successor = _plainAccount(920005);
    await Accounts.installCredentials(successor);
    account.gatedJar.releaseSave(hold);
    await result;
    await drain;
    expect(coordinator.liveOperationCount, 0);
    expect(await _cookie(successor, 'predecessor_write'), isNull);
    expect(await _cookie(successor, 'SESSDATA'), 'session-successor');
    expect(Accounts.account.get('920005'), same(successor));
  });

  test('real save failure in the error path releases the admission exactly once', () async {
    final account = LoginAccount(
      _ThrowingJar(920006),
      'access-throwing',
      'refresh-throwing',
    )..activated = true;
    await Accounts.installCredentials(account);
    final response = send(account);
    final request = await adapter.nextRequest();
    final result = expectLater(
      response,
      throwsA(isA<DioException>().having(
        (error) => error.error,
        'wrapped error',
        isA<StateError>(),
      )),
    );
    request.complete(
      status: 403,
      cookies: ['real_write=one; Domain=.bilibili.com; Path=/'],
    );
    await result;
    expect(await _cookie(account, 'real_write'), 'one');
    expect(coordinator.admittedCount, 0);
    expect(coordinator.liveOperationCount, 0);
    await coordinator.freeze();
  });

  test('real Hive onChange failure in the error path releases the admission exactly once', () async {
    final account = _loginAccount(920007);
    await Accounts.installCredentials(account);
    final probe = _EncodingProbeState();
    Hive.registerAdapter<LoginAccount>(_EncodingProbeAdapter(probe), override: true);
    try {
      final response = send(account);
      final request = await adapter.nextRequest();
      probe.failure = StateError('synthetic Hive write failure');
      final result = expectLater(
        response,
        throwsA(isA<DioException>().having(
          (error) => error.error,
          'wrapped error',
          isA<StateError>(),
        )),
      );
      request.complete(
        status: 403,
        cookies: ['persist_then_fail=one; Domain=.bilibili.com; Path=/'],
      );
      await result;
      expect(probe.writes, greaterThan(0));
      expect(await _cookie(account, 'persist_then_fail'), 'one');
      expect(coordinator.admittedCount, 0);
      expect(coordinator.liveOperationCount, 0);
      await coordinator.freeze();
    } finally {
      Hive.registerAdapter<LoginAccount>(LoginAccountAdapter(), override: true);
    }
  });

  test('onRequest consumes the injected read-only credential context', () async {
    final account = _loginAccount(920008);
    await Accounts.installCredentials(account);
    final counter = CountingCredentialReader();
    final wired = Dio(
      BaseOptions(responseType: ResponseType.plain, followRedirects: false),
    )
      ..httpClientAdapter = adapter
      ..interceptors.add(
        AccountManager(
          writeBackCoordinator: coordinator,
          credentialReader: counter,
        ),
      );
    final response = wired.get<String>(
      _origin.toString(),
      options: Options(extra: {'account': account}),
    );
    final request = await adapter.nextRequest();
    expect(counter.captures, 1);
    expect(request.options.headers['x-bili-mid'], '920008');
    expect(request.options.headers['referer'], isNotEmpty);
    request.complete(status: 200, cookies: const []);
    await expectLater(response, completes);
    wired.close(force: true);
  });

  test('onRequest rejects when the read-only context is unavailable', () async {
    final account = _loginAccount(920009);
    await Accounts.installCredentials(account);
    final denied = Dio(
      BaseOptions(responseType: ResponseType.plain, followRedirects: false),
    )
      ..httpClientAdapter = adapter
      ..interceptors.add(
        AccountManager(
          writeBackCoordinator: coordinator,
          credentialReader: const DeniedCredentialReader(),
        ),
      );
    final response = denied.get<String>(
      _origin.toString(),
      options: Options(extra: {'account': account}),
    );
    await expectLater(
      response,
      throwsA(isA<DioException>().having(
        (error) => error.type,
        'type',
        DioExceptionType.cancel,
      )),
    );
    expect(adapter.fetchCount, 0);
    denied.close(force: true);
  });
}

class _EncodingProbeState {
  int writes = 0;
  StateError? failure;
}

/// Real Hive calls the production type9 encoder before this synthetic failure.
/// This tests error forwarding, not a post-disk acknowledgment or durable receipt.
final class _EncodingProbeAdapter extends LoginAccountAdapter {
  _EncodingProbeAdapter(this.probe);

  final _EncodingProbeState probe;

  @override
  void write(BinaryWriter writer, LoginAccount obj) {
    probe.writes++;
    super.write(writer, obj);
    final error = probe.failure;
    if (error != null) throw error;
  }
}

class _PendingRequest {
  _PendingRequest(this.options);

  final RequestOptions options;
  final Completer<ResponseBody> response = Completer<ResponseBody>();

  void complete({
    required int status,
    required List<String> cookies,
    List<Uri>? locations,
  }) {
    response.complete(
      ResponseBody.fromString(
        '{}',
        status,
        isRedirect: status >= 300 && status < 400,
        headers: {
          Headers.contentTypeHeader: ['text/plain'],
          HttpHeaders.setCookieHeader: cookies,
          if (locations != null && locations.isNotEmpty)
            HttpHeaders.locationHeader: [
              for (final location in locations) location.toString(),
            ],
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
