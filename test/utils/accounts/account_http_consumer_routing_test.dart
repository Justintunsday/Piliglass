// Drives the real [VideoHttp] credential consumers through the production
// Request.dio pipeline and the production AccountManager interceptor with an
// offline controlled adapter. Covers purpose resolution, owner provenance,
// in-flight slot switches, same-MID replacement and the nullable gates; it
// makes no network request and grants no production authority.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

final _cookieOrigin = Uri.parse('https://www.bilibili.com/github/account-fixture');

LoginAccount _account(
  int mid, {
  String session = 'initial',
  Set<AccountType>? types,
}) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'csrf-$mid',
    'SESSDATA': session,
  }),
  'access-$session',
  'refresh-$session',
  types,
)..activated = true;

Future<String?> _cookie(
  Account account,
  String name, {
  Uri? uri,
}) async {
  final cookies = await account.cookieJar.loadForRequest(uri ?? _cookieOrigin);
  for (final cookie in cookies) {
    if (cookie.name == name) return cookie.value;
  }
  return null;
}

void main() {
  late AccountTestStorage storage;
  late _ControlledAdapter adapter;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });

  setUp(() async {
    await storage.reset();
    adapter = _ControlledAdapter();
    Request.dio
      ..interceptors.clear()
      ..httpClientAdapter = adapter
      ..interceptors.add(AccountManager());
  });

  tearDown(() {
    Request.dio
      ..interceptors.clear()
      ..httpClientAdapter = _IdleAdapter();
  });

  tearDownAll(() => storage.close());

  test('tvPlayUrl sends the video slot access key and writes response cookies only to the video owner', () async {
    final video = _account(301, session: 'video-owner');
    final main = _account(302, session: 'main-owner');
    final recommend = _account(303, session: 'recommend-owner');
    await Accounts.installCredentials(video);
    await Accounts.installCredentials(main);
    await Accounts.installCredentials(recommend);
    Accounts.selectTemporarily(AccountType.main, main);
    Accounts.selectTemporarily(AccountType.recommend, recommend);
    await Accounts.set(AccountType.video, video);
    expect(Accounts.get(AccountType.video), same(video));

    final stateFuture = VideoHttp.tvPlayUrl(cid: 11, objectId: 22, playurlType: 1);
    final request = await adapter.nextRequest();
    expect(request.options.path, Api.tvPlayUrl);
    expect(request.options.extra['account'], same(video));
    expect(request.options.queryParameters['access_key'], 'access-video-owner');
    expect(request.options.queryParameters['mobile_access_key'], 'access-video-owner');
    expect(request.options.queryParameters['appkey'], isNotNull);
    expect(request.options.queryParameters['ts'], isNotNull);
    expect(request.options.queryParameters['sign'], isNotNull);
    expect(request.options.headers['x-bili-mid'], '301');
    expect(
      request.options.headers[HttpHeaders.cookieHeader],
      contains('SESSDATA=video-owner'),
    );

    request.complete(
      body: const {'code': -1, 'message': 'fixture'},
      cookies: ['from_tv=path-resolved; Domain=.bilibili.com; Path=/'],
    );
    final state = await stateFuture;
    expect(state, isA<Error>());
    expect((state as Error).errMsg, 'fixture');
    expect(await _cookie(video, 'from_tv'), 'path-resolved');
    expect(await _cookie(main, 'from_tv'), isNull);
    expect(await _cookie(recommend, 'from_tv'), isNull);
  });

  test('tvPlayUrl keeps the bound video owner across an in-flight video slot switch', () async {
    final video = _account(311, session: 'video-owner');
    final other = _account(312, session: 'video-switch');
    final main = _account(313, session: 'main-owner');
    await Accounts.installCredentials(video);
    await Accounts.installCredentials(other);
    await Accounts.installCredentials(main);
    Accounts.selectTemporarily(AccountType.main, main);
    await Accounts.set(AccountType.video, video);
    final stamp = Accounts.captureRequest(video)!;

    final stateFuture = VideoHttp.tvPlayUrl(cid: 12, objectId: 23, playurlType: 1);
    final request = await adapter.nextRequest();
    expect(request.options.extra['account'], same(video));
    expect(request.options.queryParameters['access_key'], 'access-video-owner');
    Accounts.selectTemporarily(AccountType.video, other);
    expect(Accounts.get(AccountType.video), same(other));
    // Switching the purpose slot does not revoke the bound owner: its
    // legitimate response write must still land, and the new slot receives
    // nothing.
    expect(Accounts.isCurrentRequest(stamp), isTrue);

    request.complete(
      body: const {'code': -1, 'message': 'fixture'},
      cookies: ['from_tv_switch=kept; Domain=.bilibili.com; Path=/'],
    );
    final state = await stateFuture;
    expect(state, isA<Error>());
    expect(await _cookie(video, 'from_tv_switch'), 'kept');
    expect(await _cookie(other, 'from_tv_switch'), isNull);
    expect(await _cookie(main, 'from_tv_switch'), isNull);
  });

  test('tvPlayUrl performs no cookie write after a same-MID video replacement', () async {
    final video = _account(321, session: 'video-owner');
    await Accounts.installCredentials(video);
    await Accounts.set(AccountType.video, video);
    final stamp = Accounts.captureRequest(video)!;

    final stateFuture = VideoHttp.tvPlayUrl(cid: 13, objectId: 24, playurlType: 1);
    final request = await adapter.nextRequest();
    expect(request.options.extra['account'], same(video));
    final replacement = _account(321, session: 'video-replacement');
    await Accounts.installCredentials(replacement);
    expect(Accounts.ownsCredentials(video), isFalse);
    expect(Accounts.isCurrentRequest(stamp), isFalse);

    request.complete(
      body: const {'code': -1, 'message': 'fixture'},
      cookies: ['from_replace=stale; Domain=.bilibili.com; Path=/'],
    );
    final state = await stateFuture;
    expect(state, isA<Error>());
    expect(await _cookie(video, 'from_replace'), isNull);
    expect(await _cookie(replacement, 'from_replace'), isNull);
  });

  test('tvPlayUrl binds the anonymous singleton and omits the access key without a video login', () async {
    final main = _account(331, session: 'main-owner');
    final recommend = _account(332, session: 'recommend-owner');
    await Accounts.installCredentials(main);
    await Accounts.installCredentials(recommend);
    Accounts.selectTemporarily(AccountType.main, main);
    Accounts.selectTemporarily(AccountType.recommend, recommend);
    expect(Accounts.get(AccountType.video), isA<AnonymousAccount>());

    final stateFuture = VideoHttp.tvPlayUrl(cid: 14, objectId: 25, playurlType: 1);
    final request = await adapter.nextRequest();
    expect(request.options.path, Api.tvPlayUrl);
    expect(request.options.extra['account'], isA<AnonymousAccount>());
    expect(request.options.queryParameters.containsKey('access_key'), isFalse);
    expect(request.options.queryParameters.containsKey('mobile_access_key'), isFalse);
    expect(request.options.headers['x-bili-mid'], isNull);

    request.complete(
      body: const {'code': -1, 'message': 'fixture'},
      cookies: ['from_anon=ignored; Domain=.bilibili.com; Path=/'],
    );
    final state = await stateFuture;
    expect(state, isA<Error>());
    expect(await _cookie(main, 'from_anon'), isNull);
    expect(await _cookie(recommend, 'from_anon'), isNull);
  });

  test('a dislike without a main login rejects before sending any request', () async {
    expect(Accounts.get(AccountType.main), isA<AnonymousAccount>());
    final state = await VideoHttp.dislikeVideo(bvid: 'BV1xx411c7mD', type: true);
    expect(state, isA<Error>());
    expect((state as Error).errMsg, '请退出账号后重新登录');
    expect(adapter.fetchCount, 0);
  });

  test('dislikeVideo injects the main slot access key into the signed app request', () async {
    final main = _account(341, session: 'main-owner');
    await Accounts.installCredentials(main);
    Accounts.selectTemporarily(AccountType.main, main);

    final stateFuture = VideoHttp.dislikeVideo(bvid: 'BV1xx411c7mD', type: true);
    final request = await adapter.nextRequest();
    expect(request.options.path, Api.dislikeVideo);
    expect(request.options.extra['account'], same(main));
    final data = request.options.data as Map;
    expect(data['access_key'], 'access-main-owner');
    expect(data['appkey'], isNotNull);
    expect(data['sign'], isNotNull);
    expect(request.options.headers['x-bili-mid'], '341');
    expect(request.options.headers[HttpHeaders.cookieHeader], isNull);

    request.complete(
      body: const {'code': -1, 'message': 'fixture'},
      cookies: ['from_app=ignored; Domain=.bilibili.com; Path=/'],
    );
    final state = await stateFuture;
    expect(state, isA<Error>());
    // App endpoints never write response cookies back to the bound owner.
    expect(await _cookie(main, 'from_app'), isNull);
  });

  test('feed dislike builders without a recommend login reject before sending any request', () async {
    expect(Accounts.get(AccountType.recommend), isA<AnonymousAccount>());
    final dislike = await VideoHttp.feedDislike(goto: 'video', id: 1, reasonId: 1);
    expect(dislike, isA<Error>());
    expect((dislike as Error).errMsg, '请退出账号后重新登录');
    final cancel = await VideoHttp.feedDislikeCancel(goto: 'video', id: 1, reasonId: 1);
    expect(cancel, isA<Error>());
    expect((cancel as Error).errMsg, '请退出账号后重新登录');
    expect(adapter.fetchCount, 0);
  });

  test('feedDislike injects the recommend slot access key into the signed app query', () async {
    final recommend = _account(351, session: 'recommend-owner');
    await Accounts.installCredentials(recommend);
    Accounts.selectTemporarily(AccountType.recommend, recommend);

    final stateFuture = VideoHttp.feedDislike(goto: 'video', id: 55, reasonId: 7);
    final request = await adapter.nextRequest();
    expect(request.options.path, Api.feedDislike);
    expect(request.options.extra['account'], same(recommend));
    expect(request.options.queryParameters['access_key'], 'access-recommend-owner');
    expect(request.options.queryParameters['appkey'], isNotNull);
    expect(request.options.queryParameters['sign'], isNotNull);
    expect(request.options.headers['x-bili-mid'], '351');
    expect(request.options.headers[HttpHeaders.cookieHeader], isNull);

    request.complete(
      body: const {'code': 0},
      cookies: ['from_app=ignored; Domain=.bilibili.com; Path=/'],
    );
    final state = await stateFuture;
    expect(state, isA<Success>());
    expect(await _cookie(recommend, 'from_app'), isNull);
  });

  test('an app feed request keeps the recommend owner query across an in-flight slot switch', () async {
    final recommend = _account(361, session: 'recommend-owner');
    final other = _account(362, session: 'recommend-switch');
    await Accounts.installCredentials(recommend);
    await Accounts.installCredentials(other);
    Accounts.selectTemporarily(AccountType.recommend, recommend);

    final stateFuture = VideoHttp.feedDislikeCancel(
      goto: 'video',
      id: 66,
      feedbackId: 9,
    );
    final request = await adapter.nextRequest();
    expect(request.options.extra['account'], same(recommend));
    expect(request.options.queryParameters['access_key'], 'access-recommend-owner');
    Accounts.selectTemporarily(AccountType.recommend, other);
    expect(Accounts.get(AccountType.recommend), same(other));

    request.complete(
      body: const {'code': 0},
      cookies: ['from_switch=ignored; Domain=.bilibili.com; Path=/'],
    );
    final state = await stateFuture;
    expect(state, isA<Success>());
    expect(await _cookie(recommend, 'from_switch'), isNull);
    expect(await _cookie(other, 'from_switch'), isNull);
  });
}

class _PendingRequest {
  final RequestOptions options;
  final Completer<ResponseBody> response = Completer<ResponseBody>();

  _PendingRequest(this.options);

  void complete({
    required Map<String, Object?> body,
    List<String> cookies = const [],
  }) {
    response.complete(
      ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
          HttpHeaders.setCookieHeader: cookies,
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

/// Keeps account clear/reset side effects off the network between tests
/// (mirrors the storage helper's activation adapter).
class _IdleAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => Future.value(
    ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    ),
  );

  @override
  void close({bool force = false}) {}
}
