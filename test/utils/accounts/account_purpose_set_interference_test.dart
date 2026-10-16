// Drives the real Accounts.set purpose lifecycle: the synchronous slot/type
// edit, the post-await owner/stamp revalidations and the observable publish
// chain (LoginUtils main effects, heartbeat anonymity) under concurrent
// selection, replacement, deleteAll and set interference. Real Hive storage,
// a controlled Dio adapter for the activation/userInfo/historyStatus awaits and
// the documented LoginUtils seams; no production behavior is mocked away.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/pages/mine/controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';

import 'account_test_storage.dart';

final _loggedInUserInfo = jsonEncode({
  'code': 0,
  'data': {
    'isLogin': true,
    'mid': 4242,
    'face': 'https://example.invalid/face-4242.png',
  },
});
const _historyStatusOk = '{"code":0,"data":true}';

LoginAccount _account(int mid, {bool activated = true}) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'csrf-$mid',
    'SESSDATA': 'session-$mid',
  }),
  'access-$mid',
  'refresh-$mid',
)..activated = activated;

class _PendingResponse {
  _PendingResponse(this.options);

  final RequestOptions options;
  final completer = Completer<ResponseBody>();

  void complete(String body) {
    completer.complete(ResponseBody.fromString(
      body,
      200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    ));
  }
}

class _ControlledAdapter implements HttpClientAdapter {
  /// Actual request count, so a stale path can be proven by "no request was
  /// even started" instead of an inferred absence of effects.
  int issued = 0;
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
    issued++;
    final request = _PendingResponse(options);
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(request);
    } else {
      _requests.add(request);
    }
    return request.completer.future;
  }

  @override
  void close({bool force = false}) {}
}

/// Answers immediately so fixture resets (clear can activate buvid) never wait
/// on a test's controlled adapter left over from a previous case.
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
  late _ControlledAdapter adapter;
  late int mirrorCalls;
  late int publishCalls;
  late Future<void> Function(Account, List<Cookie>, bool Function())
      priorMirror;
  late Future<void> Function() priorClear;
  late Future<void> Function(UserInfoData) priorPublish;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
    // The main-purpose publish chain can reach LoginUtils.onLogoutMain, whose
    // production wiring touches the real userInfo box and AccountService.
    GStorage.userInfo = await Hive.openBox<UserInfoData>('userInfo');
    if (!Get.isRegistered<AccountService>()) {
      Get.put(AccountService(), permanent: true);
    }
  });

  setUp(() async {
    await storage.reset();
    await GStorage.localCache.delete(LocalCacheKey.historyPause);
    adapter = _ControlledAdapter();
    mirrorCalls = 0;
    publishCalls = 0;
    priorMirror = LoginUtils.webCookieMirrorWriter;
    priorClear = LoginUtils.webCookieClearer;
    priorPublish = LoginUtils.loginMainPublisher;
    LoginUtils.webCookieMirrorWriter = (account, cookies, isCurrent) {
      mirrorCalls++;
      return Future<void>.value();
    };
    LoginUtils.webCookieClearer = Future<void>.value;
    LoginUtils.loginMainPublisher = (response) {
      publishCalls++;
      return Future<void>.value();
    };
    Request.dio
      ..httpClientAdapter.close(force: true)
      ..httpClientAdapter = adapter;
  });

  tearDown(() {
    LoginUtils.webCookieMirrorWriter = priorMirror;
    LoginUtils.webCookieClearer = priorClear;
    LoginUtils.loginMainPublisher = priorPublish;
    Request.dio
      ..interceptors.clear()
      ..httpClientAdapter = _ImmediateAdapter();
  });

  tearDownAll(() => storage.close());

  test('set(main) reaches the publish chain through activation, userInfo and historyStatus', () async {
    final account = _account(701, activated: false);
    await Accounts.installCredentials(account);
    expect(Accounts.get(AccountType.main), isA<AnonymousAccount>());

    final setting = Accounts.set(AccountType.main, account);
    final activation = await adapter.nextRequest();
    expect(activation.options.path, Api.activateBuvidApi);
    expect(account.activated, isTrue);
    activation.complete('{}');

    final userInfo = await adapter.nextRequest();
    expect(userInfo.options.path, Api.userInfo);
    userInfo.complete(_loggedInUserInfo);
    final history = await adapter.nextRequest();
    expect(history.options.path, Api.historyStatus);
    history.complete(_historyStatusOk);

    await setting;
    expect(Accounts.get(AccountType.main), same(account));
    expect(account.type, contains(AccountType.main));
    expect(mirrorCalls, 1);
    expect(publishCalls, 1);
    expect(await GStorage.localCache.get(LocalCacheKey.historyPause), isTrue);
    expect(adapter.issued, 3);
  });

  test('set(main) cannot publish after an in-flight selection switch', () async {
    final account = _account(702, activated: false);
    final other = _account(703);
    await Accounts.installCredentials(account);
    await Accounts.installCredentials(other);
    final stamp = Accounts.captureRequest(account)!;

    final setting = Accounts.set(AccountType.main, account);
    final activation = await adapter.nextRequest();
    Accounts.selectTemporarily(AccountType.main, other);
    expect(Accounts.get(AccountType.main), same(other));
    activation.complete('{}');

    await setting;
    expect(adapter.issued, 1);
    expect(mirrorCalls, 0);
    expect(publishCalls, 0);
    expect(Accounts.get(AccountType.main), same(other));
    // The stamp alone still accepts the old owner: the slot identity check is
    // what stops the stale publish.
    expect(Accounts.isCurrentRequest(stamp), isTrue);
    expect(account.type, contains(AccountType.main));
    expect(other.type, isNot(contains(AccountType.main)));
    expect(await GStorage.localCache.get(LocalCacheKey.historyPause), isNull);
  });

  test('set(main) cannot publish after an in-flight same-MID replacement', () async {
    final account = _account(704, activated: false);
    await Accounts.installCredentials(account);
    final stamp = Accounts.captureRequest(account)!;

    final setting = Accounts.set(AccountType.main, account);
    final activation = await adapter.nextRequest();
    final replacement = _account(704);
    await Accounts.installCredentials(replacement);
    expect(Accounts.ownsCredentials(account), isFalse);
    expect(Accounts.isCurrentRequest(stamp), isFalse);
    activation.complete('{}');

    await setting;
    expect(adapter.issued, 1);
    expect(mirrorCalls, 0);
    expect(publishCalls, 0);
    expect(Accounts.get(AccountType.main), same(replacement));
    expect(replacement.type, contains(AccountType.main));
    expect(Accounts.captureRequest(account), isNull);
    expect(await GStorage.localCache.get(LocalCacheKey.historyPause), isNull);
  });

  test('a later set wins coherently while the first waits and never double-publishes', () async {
    final account = _account(705, activated: false);
    final later = _account(706);
    await Accounts.installCredentials(account);
    await Accounts.installCredentials(later);

    final first = Accounts.set(AccountType.main, account);
    final activation = await adapter.nextRequest();
    expect(activation.options.path, Api.activateBuvidApi);

    final second = Accounts.set(AccountType.main, later);
    final userInfo = await adapter.nextRequest();
    expect(userInfo.options.path, Api.userInfo);
    userInfo.complete(_loggedInUserInfo);
    final history = await adapter.nextRequest();
    expect(history.options.path, Api.historyStatus);
    history.complete(_historyStatusOk);
    await second;

    activation.complete('{}');
    await first;

    expect(Accounts.get(AccountType.main), same(later));
    expect(later.type, contains(AccountType.main));
    // The later set removes main from the slot owner it saw (the first owner):
    // the interrupted synchronous edit is not rolled back, so last-writer-wins
    // stays coherent.
    expect(account.type, isNot(contains(AccountType.main)));
    expect(adapter.issued, 3);
    expect(mirrorCalls, 1);
    expect(publishCalls, 1);
  });

  test('set(main) cannot publish after deleteAll revokes the in-flight owner', () async {
    final account = _account(707, activated: false);
    await Accounts.installCredentials(account);

    final setting = Accounts.set(AccountType.main, account);
    final activation = await adapter.nextRequest();
    await Accounts.deleteAll({account});
    activation.complete('{}');

    await setting;
    expect(adapter.issued, 1);
    expect(mirrorCalls, 0);
    expect(publishCalls, 0);
    expect(Accounts.get(AccountType.main), isA<AnonymousAccount>());
    expect(Accounts.captureRequest(account), isNull);
    expect(await GStorage.localCache.get(LocalCacheKey.historyPause), isNull);
  });

  test('set(heartbeat) still enforces the post-await owner check for anonymity', () async {
    MineController.anonymity.value = true;
    final account = _account(708, activated: false);
    await Accounts.installCredentials(account);

    final setting = Accounts.set(AccountType.heartbeat, account);
    final activation = await adapter.nextRequest();
    activation.complete('{}');
    await setting;

    expect(Accounts.get(AccountType.heartbeat), same(account));
    expect(MineController.anonymity.value, isFalse);
    expect(adapter.issued, 1);
  });

  test('a switched heartbeat slot is not overwritten by the stale anonymity effect', () async {
    MineController.anonymity.value = true;
    final account = _account(709, activated: false);
    final other = _account(710);
    await Accounts.installCredentials(account);
    await Accounts.installCredentials(other);

    final setting = Accounts.set(AccountType.heartbeat, account);
    final activation = await adapter.nextRequest();
    Accounts.selectTemporarily(AccountType.heartbeat, other);
    activation.complete('{}');
    await setting;

    expect(Accounts.get(AccountType.heartbeat), same(other));
    expect(MineController.anonymity.value, isTrue);
    expect(adapter.issued, 1);
  });
}
