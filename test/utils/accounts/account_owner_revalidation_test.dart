import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/services/native_accounts/account_write_back_coordinator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:PiliPlus/utils/request_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

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

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });
  setUp(() async {
    await storage.reset();
    await GStorage.localCache.delete(LocalCacheKey.historyPause);
  });
  tearDown(() {
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
    expect(coordinator.liveOperationCount, 0);
    expect(GStorage.localCache.get(LocalCacheKey.historyPause), isNull);
  });
}
