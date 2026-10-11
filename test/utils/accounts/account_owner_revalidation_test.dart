import 'dart:async';
import 'dart:collection';
import 'dart:io' show Cookie;
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/services/native_accounts/account_write_back_coordinator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:PiliPlus/utils/request_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';

import 'account_test_storage.dart';

LoginAccount _account(int mid) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'csrf-$mid',
    'SESSDATA': 'session-$mid',
  }),
  'access-$mid',
  'refresh-$mid',
)..activated = true;

class _PendingResponse {
  _PendingResponse(this.options);

  final RequestOptions options;
  final completer = Completer<ResponseBody>();

  void complete(String body, {int status = 200}) {
    completer.complete(ResponseBody.fromString(
      body,
      status,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    ));
  }
}

class _ControlledAdapter implements HttpClientAdapter {
  final Queue<_PendingResponse> _requests = Queue<_PendingResponse>();
  final Queue<Completer<_PendingResponse>> _waiters =
      Queue<Completer<_PendingResponse>>();

  Future<_PendingResponse> nextRequest() {
    if (_requests.isNotEmpty) return Future.value(_requests.removeFirst());
    final waiter = Completer<_PendingResponse>();
    _waiters.add(waiter);
    return waiter.future;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final pending = _PendingResponse(options);
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(pending);
    } else {
      _requests.add(pending);
    }
    return pending.completer.future;
  }

  @override
  void close({bool force = false}) {}
}

/// Answers immediately so fixture resets (clear triggers buvid activation)
/// never wait on a test's controlled adapter left over from a previous case.
class _ImmediateAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => Future.value(ResponseBody.fromString(
    '{}',
    200,
    headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
  ));

  @override
  void close({bool force = false}) {}
}

void main() {
  late AccountTestStorage storage;
  late Future<void> Function(Account, List<Cookie>, bool Function())
      priorMirror;
  late Future<void> Function() priorClear;
  late Future<void> Function(UserInfoData) priorPublish;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
    // AccountService.onInit reads Pref.userInfoCache, which needs the real
    // userInfo box; the shared fixture leaves it closed.
    GStorage.userInfo = await Hive.openBox<UserInfoData>('userInfo');
    if (!Get.isRegistered<AccountService>()) {
      Get.put(AccountService(), permanent: true);
    }
  });
  setUp(() async {
    await storage.reset();
    await GStorage.localCache.delete(LocalCacheKey.historyPause);
    priorMirror = LoginUtils.webCookieMirrorWriter;
    priorClear = LoginUtils.webCookieClearer;
    priorPublish = LoginUtils.loginMainPublisher;
    LoginUtils.webCookieMirrorWriter =
        (account, cookies, isCurrent) => Future<void>.value();
    LoginUtils.webCookieClearer = Future<void>.value;
    LoginUtils.loginMainPublisher = (response) => Future<void>.value();
  });
  tearDown(() {
    LoginUtils.webCookieMirrorWriter = priorMirror;
    LoginUtils.webCookieClearer = priorClear;
    LoginUtils.loginMainPublisher = priorPublish;
    Request.dio.httpClientAdapter = _ImmediateAdapter();
  });
  tearDownAll(() => storage.close());

  test('syncHistoryStatus awaits the real cache write of the current owner', () async {
    final account = _account(980001);
    await Accounts.installCredentials(account);
    Accounts.selectTemporarily(AccountType.heartbeat, account);
    final adapter = _ControlledAdapter();
    Request.dio.httpClientAdapter = adapter;
    final coordinator = AccountWriteBackCoordinator();
    final syncing = RequestUtils.syncHistoryStatus(coordinator: coordinator);
    final request = await adapter.nextRequest();
    expect(coordinator.liveOperationCount, 1);
    request.complete('{"code":0,"data":true}');
    await syncing;
    expect(coordinator.liveOperationCount, 0);
    expect(GStorage.localCache.get(LocalCacheKey.historyPause), true);
  });

  test('syncHistoryStatus drops the cache write when the owner changes during the await', () async {
    final a = _account(980002);
    final b = _account(980003);
    await Accounts.installCredentials(a);
    await Accounts.installCredentials(b);
    Accounts.selectTemporarily(AccountType.heartbeat, a);
    final adapter = _ControlledAdapter();
    Request.dio.httpClientAdapter = adapter;
    final coordinator = AccountWriteBackCoordinator();
    final syncing = RequestUtils.syncHistoryStatus(coordinator: coordinator);
    final request = await adapter.nextRequest();
    Accounts.selectTemporarily(AccountType.heartbeat, b);
    request.complete('{"code":0,"data":true}');
    await syncing;
    expect(GStorage.localCache.get(LocalCacheKey.historyPause), isNull);
    expect(coordinator.liveOperationCount, 0);
  });

  test('syncHistoryStatus drops the cache write after delete and reinstall', () async {
    final a = _account(980004);
    await Accounts.installCredentials(a);
    Accounts.selectTemporarily(AccountType.heartbeat, a);
    final adapter = _ControlledAdapter();
    Request.dio.httpClientAdapter = adapter;
    final coordinator = AccountWriteBackCoordinator();
    final syncing = RequestUtils.syncHistoryStatus(coordinator: coordinator);
    final request = await adapter.nextRequest();
    await Accounts.deleteAll({a});
    final reinstalled = _account(980004);
    await Accounts.installCredentials(reinstalled);
    request.complete('{"code":0,"data":true}');
    await syncing;
    expect(GStorage.localCache.get(LocalCacheKey.historyPause), isNull);
    expect(coordinator.liveOperationCount, 0);
  });

  test('clear drains the anonymous buvid activation request', () async {
    final adapter = _ControlledAdapter();
    Request.dio.httpClientAdapter = adapter;
    final coordinator = AccountWriteBackCoordinator();
    AnonymousAccount().activated = false;
    final clearing = Accounts.clear(coordinator: coordinator);
    final request = await adapter.nextRequest();
    var completed = false;
    final watcher = clearing.then((_) => completed = true);
    await Future<void>.value();
    expect(completed, false);
    expect(coordinator.liveOperationCount, 1);
    request.complete('{}');
    await watcher;
    expect(completed, true);
    expect(coordinator.liveOperationCount, 0);
  });

  test('onLoginMain does not mirror a replaced owner after the await', () async {
    final a = _account(980005);
    final b = _account(980006);
    await Accounts.installCredentials(a);
    await Accounts.installCredentials(b);
    Accounts.selectTemporarily(AccountType.main, a);
    var mirrored = false;
    var published = false;
    LoginUtils.webCookieMirrorWriter = (account, cookies, isCurrent) {
      mirrored = true;
      return Future<void>.value();
    };
    LoginUtils.loginMainPublisher = (response) {
      published = true;
      return Future<void>.value();
    };
    final gate = Completer<LoadingState<UserInfoData>>();
    final coordinator = AccountWriteBackCoordinator();
    final running = LoginUtils.onLoginMain(
      coordinator: coordinator,
      userInfo: () => gate.future,
    );
    await Future<void>.value();
    expect(coordinator.liveOperationCount, 1);
    Accounts.selectTemporarily(AccountType.main, b);
    gate.complete(Success(UserInfoData.fromJson(const {})));
    await running;
    expect(mirrored, false);
    expect(published, false);
    expect(coordinator.liveOperationCount, 0);
    expect(GStorage.localCache.get(LocalCacheKey.historyPause), isNull);
  });

  test('onLoginMain stops after the owner changes during the WK mirror', () async {
    final a = _account(980007);
    final b = _account(980008);
    await Accounts.installCredentials(a);
    await Accounts.installCredentials(b);
    Accounts.selectTemporarily(AccountType.main, a);
    final mirrorStarted = Completer<void>();
    final mirrorGate = Completer<void>();
    var staleAtResume = false;
    var published = false;
    LoginUtils.webCookieMirrorWriter = (account, cookies, isCurrent) async {
      if (!mirrorStarted.isCompleted) mirrorStarted.complete();
      await mirrorGate.future;
      staleAtResume = !isCurrent();
    };
    LoginUtils.loginMainPublisher = (response) {
      published = true;
      return Future<void>.value();
    };
    final coordinator = AccountWriteBackCoordinator();
    final running = LoginUtils.onLoginMain(
      coordinator: coordinator,
      userInfo: () => Future.value(Success(UserInfoData.fromJson(const {}))),
    );
    await mirrorStarted.future;
    Accounts.selectTemporarily(AccountType.main, b);
    mirrorGate.complete();
    await running;
    expect(staleAtResume, true);
    expect(published, false);
    expect(GStorage.localCache.get(LocalCacheKey.historyPause), isNull);
    expect(coordinator.liveOperationCount, 0);
  });

  test('onLoginMain drops publication when the owner is deleted and reinstalled during the history await', () async {
    final a = _account(980009);
    await Accounts.installCredentials(a);
    Accounts.selectTemporarily(AccountType.main, a);
    var published = false;
    LoginUtils.loginMainPublisher = (response) {
      published = true;
      return Future<void>.value();
    };
    final adapter = _ControlledAdapter();
    Request.dio.httpClientAdapter = adapter;
    final coordinator = AccountWriteBackCoordinator();
    final running = LoginUtils.onLoginMain(
      coordinator: coordinator,
      userInfo: () => Future.value(Success(UserInfoData.fromJson(const {'isLogin': true}))),
    );
    final request = await adapter.nextRequest();
    await a.delete();
    final reinstalled = _account(980009);
    await Accounts.installCredentials(reinstalled);
    request.complete('{"code":0,"data":true}');
    await running;
    expect(published, false);
    expect(coordinator.liveOperationCount, 0);
  });

  test('a newer login mirror runs strictly after an in-flight stale mirror', () async {
    final a = _account(980010);
    final b = _account(980011);
    await Accounts.installCredentials(a);
    await Accounts.installCredentials(b);
    Accounts.selectTemporarily(AccountType.main, a);
    final calls = <String>[];
    final mirrorStarted = Completer<void>();
    final mirrorGate = Completer<void>();
    LoginUtils.webCookieMirrorWriter = (account, cookies, isCurrent) async {
      calls.add('mirror-${account.mid}');
      if (account.mid == 980010) {
        if (!mirrorStarted.isCompleted) mirrorStarted.complete();
        await mirrorGate.future;
      }
    };
    final coordinator = AccountWriteBackCoordinator();
    final first = LoginUtils.setWebCookie(account: a, coordinator: coordinator);
    await mirrorStarted.future;
    Accounts.selectTemporarily(AccountType.main, b);
    final second = LoginUtils.setWebCookie(account: b, coordinator: coordinator);
    await Future<void>.value();
    expect(calls, ['mirror-980010']);
    mirrorGate.complete();
    await Future.wait([first, second]);
    expect(calls, ['mirror-980010', 'mirror-980011']);
    expect(coordinator.liveOperationCount, 0);
  });

  test('a logout clear runs after an in-flight login mirror', () async {
    final a = _account(980012);
    await Accounts.installCredentials(a);
    Accounts.selectTemporarily(AccountType.main, a);
    final calls = <String>[];
    final mirrorStarted = Completer<void>();
    final mirrorGate = Completer<void>();
    LoginUtils.webCookieMirrorWriter = (account, cookies, isCurrent) async {
      calls.add('mirror-start');
      if (!mirrorStarted.isCompleted) mirrorStarted.complete();
      await mirrorGate.future;
      calls.add('mirror-end');
    };
    LoginUtils.webCookieClearer = () {
      calls.add('clear');
      return Future<void>.value();
    };
    final coordinator = AccountWriteBackCoordinator();
    final running = LoginUtils.onLoginMain(
      coordinator: coordinator,
      userInfo: () => Future.value(Success(UserInfoData.fromJson(const {}))),
    );
    await mirrorStarted.future;
    final loggingOut = LoginUtils.onLogoutMain(coordinator: coordinator);
    await Future<void>.value();
    expect(calls, ['mirror-start']);
    mirrorGate.complete();
    await Future.wait([running, loggingOut]);
    expect(calls, ['mirror-start', 'mirror-end', 'clear']);
    expect(coordinator.liveOperationCount, 0);
  });

  test('a throwing mirror releases the admission exactly once', () async {
    final a = _account(980013);
    await Accounts.installCredentials(a);
    Accounts.selectTemporarily(AccountType.main, a);
    LoginUtils.webCookieMirrorWriter = (account, cookies, isCurrent) {
      throw StateError('synthetic mirror failure');
    };
    final coordinator = AccountWriteBackCoordinator();
    await expectLater(
      LoginUtils.onLoginMain(
        coordinator: coordinator,
        userInfo: () => Future.value(Success(UserInfoData.fromJson(const {}))),
      ),
      throwsA(isA<StateError>()),
    );
    expect(coordinator.liveOperationCount, 0);
  });

  test('the current owner completes mirror and publication exactly once', () async {
    final a = _account(980014);
    await Accounts.installCredentials(a);
    Accounts.selectTemporarily(AccountType.main, a);
    var mirrorCalls = 0;
    var publishCalls = 0;
    LoginUtils.webCookieMirrorWriter = (account, cookies, isCurrent) {
      mirrorCalls++;
      expect(isCurrent(), true);
      return Future<void>.value();
    };
    LoginUtils.loginMainPublisher = (response) {
      publishCalls++;
      return Future<void>.value();
    };
    final coordinator = AccountWriteBackCoordinator();
    await LoginUtils.onLoginMain(
      coordinator: coordinator,
      userInfo: () => Future.value(Success(UserInfoData.fromJson(const {'isLogin': true}))),
    );
    expect(mirrorCalls, 1);
    expect(publishCalls, 1);
    expect(coordinator.liveOperationCount, 0);
  });
}
