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

LoginAccount _nullKeyAccount(int mid, {String session = 'null-key'}) =>
    LoginAccount(
      BiliCookieJar.fromJson({
        'DedeUserID': '$mid',
        'bili_jct': 'csrf-$mid',
        'SESSDATA': session,
      }),
      null,
      'refresh-$session',
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

  _BindingBarrierInterceptor installBarrier() {
    final barrier = _BindingBarrierInterceptor();
    Request.dio
      ..interceptors.clear()
      ..interceptors.add(barrier)
      ..interceptors.add(AccountManager());
    return barrier;
  }

  Future<({bool fetched, bool resolved})> settleOutcome(
    Future<LoadingState<dynamic>> stateFuture,
  ) async {
    var resolved = false;
    unawaited(stateFuture.then((_) {
      resolved = true;
    }));
    for (var i = 0; i < 50 && !resolved && adapter.fetchCount == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return (fetched: adapter.fetchCount > 0, resolved: resolved);
  }

  Future<void> expectPrebindVideoOutcome(
    Future<LoadingState<dynamic>> stateFuture,
    LoginAccount owner,
    String token,
  ) async {
    final outcome = await settleOutcome(stateFuture);
    if (!outcome.fetched) {
      expect(
        outcome.resolved,
        isTrue,
        reason: 'the pre-binding request neither fetched nor resolved',
      );
      expect(await stateFuture, isA<Error>());
      return;
    }
    final request = await adapter.nextRequest();
    // The sent request must be consistent with the owner whose access key and
    // signature were read synchronously; never a mixed A-query/B-credential.
    expect(
      request.options.extra['account'],
      same(owner),
      reason: 'the sent request must keep the owner whose key/signature it carries',
    );
    expect(request.options.queryParameters['access_key'], 'access-$token');
    expect(request.options.queryParameters['mobile_access_key'], 'access-$token');
    expect(request.options.headers['x-bili-mid'], '${owner.mid}');
    expect(
      request.options.headers[HttpHeaders.cookieHeader],
      contains('SESSDATA=$token'),
    );
    request.complete(
      body: const {'code': -1, 'message': 'fixture'},
      cookies: ['prebind_write=kept; Domain=.bilibili.com; Path=/'],
    );
    expect(await stateFuture, isA<Error>());
    expect(await _cookie(owner, 'prebind_write'), 'kept');
  }

  Future<void> expectPrebindAppOutcome(
    Future<LoadingState<dynamic>> stateFuture,
    LoginAccount owner,
    String token,
    String path, {
    bool keyInBody = false,
  }) async {
    final outcome = await settleOutcome(stateFuture);
    if (!outcome.fetched) {
      expect(
        outcome.resolved,
        isTrue,
        reason: 'the pre-binding request neither fetched nor resolved',
      );
      expect(await stateFuture, isA<Error>());
      return;
    }
    final request = await adapter.nextRequest();
    expect(request.options.path, path);
    // The signed app request must keep the owner whose key the gate validated;
    // switching the slot before binding must never reroute it to another owner.
    expect(
      request.options.extra['account'],
      same(owner),
      reason: 'the signed app request must keep the owner its gate validated',
    );
    final accessKey = keyInBody
        ? (request.options.data as Map)['access_key']
        : request.options.queryParameters['access_key'];
    expect(accessKey, 'access-$token');
    expect(request.options.headers['x-bili-mid'], '${owner.mid}');
    request.complete(body: const {'code': 0});
    expect(await stateFuture, isA<Success>());
  }

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

  test('a dislike without a main login rejects while other slots hold valid logins', () async {
    final video = _account(342, session: 'video-owner');
    final recommend = _account(343, session: 'recommend-owner');
    await Accounts.installCredentials(video);
    await Accounts.installCredentials(recommend);
    Accounts.selectTemporarily(AccountType.video, video);
    Accounts.selectTemporarily(AccountType.recommend, recommend);
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

  test('feed dislike builders without a recommend login reject while other slots hold valid logins', () async {
    final main = _account(352, session: 'main-owner');
    final video = _account(353, session: 'video-owner');
    await Accounts.installCredentials(main);
    await Accounts.installCredentials(video);
    Accounts.selectTemporarily(AccountType.main, main);
    Accounts.selectTemporarily(AccountType.video, video);
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

  test('tvPlayUrl keeps the captured video owner across the immediate post-call switch', () async {
    final videoA = _account(371, session: 'video-a');
    final videoB = _account(372, session: 'video-b');
    await Accounts.installCredentials(videoA);
    await Accounts.installCredentials(videoB);
    await Accounts.set(AccountType.video, videoA);

    final stateFuture = VideoHttp.tvPlayUrl(cid: 15, objectId: 26, playurlType: 1);
    // No await between the call and the switch: the Dio interceptor chain has
    // not executed yet, so this is the real pre-binding window.
    Accounts.selectTemporarily(AccountType.video, videoB);
    expect(Accounts.get(AccountType.video), same(videoB));
    expect(adapter.fetchCount, 0);

    await expectPrebindVideoOutcome(stateFuture, videoA, 'video-a');
    expect(await _cookie(videoB, 'prebind_write'), isNull);
  });

  test('tvPlayUrl cannot blend a pre-binding barrier slot switch into the sent request', () async {
    final videoA = _account(373, session: 'barrier-a');
    final videoB = _account(374, session: 'barrier-b');
    await Accounts.installCredentials(videoA);
    await Accounts.installCredentials(videoB);
    await Accounts.set(AccountType.video, videoA);
    final barrier = installBarrier();

    final stateFuture = VideoHttp.tvPlayUrl(cid: 16, objectId: 27, playurlType: 1);
    await barrier.entered.future;
    Accounts.selectTemporarily(AccountType.video, videoB);
    expect(adapter.fetchCount, 0);
    barrier.release();

    await expectPrebindVideoOutcome(stateFuture, videoA, 'barrier-a');
    expect(await _cookie(videoB, 'prebind_write'), isNull);
  });

  test('tvPlayUrl cancels instead of sending after a pre-binding same-MID replacement', () async {
    final video = _account(375, session: 'revoke-owner');
    await Accounts.installCredentials(video);
    await Accounts.set(AccountType.video, video);
    final barrier = installBarrier();

    final stateFuture = VideoHttp.tvPlayUrl(cid: 17, objectId: 28, playurlType: 1);
    await barrier.entered.future;
    final replacement = _account(375, session: 'revoke-replacement');
    await Accounts.installCredentials(replacement);
    expect(Accounts.ownsCredentials(video), isFalse);
    barrier.release();

    final outcome = await settleOutcome(stateFuture);
    expect(
      outcome.fetched,
      isFalse,
      reason: 'a replaced pre-binding owner must cancel before any fetch',
    );
    expect(await stateFuture, isA<Error>());
    expect(adapter.fetchCount, 0);
  });

  test('a new tvPlayUrl request after the slot switch uses the new owner consistently', () async {
    final videoA = _account(376, session: 'new-ctx-a');
    final videoB = _account(377, session: 'new-ctx-b');
    await Accounts.installCredentials(videoA);
    await Accounts.installCredentials(videoB);
    await Accounts.set(AccountType.video, videoA);
    Accounts.selectTemporarily(AccountType.video, videoB);
    expect(Accounts.get(AccountType.video), same(videoB));

    final stateFuture = VideoHttp.tvPlayUrl(cid: 18, objectId: 29, playurlType: 1);
    final request = await adapter.nextRequest();
    expect(request.options.extra['account'], same(videoB));
    expect(request.options.queryParameters['access_key'], 'access-new-ctx-b');
    expect(request.options.headers['x-bili-mid'], '377');
    expect(
      request.options.headers[HttpHeaders.cookieHeader],
      contains('SESSDATA=new-ctx-b'),
    );
    request.complete(
      body: const {'code': -1, 'message': 'fixture'},
      cookies: ['new_context=kept; Domain=.bilibili.com; Path=/'],
    );
    expect(await stateFuture, isA<Error>());
    expect(await _cookie(videoB, 'new_context'), 'kept');
    expect(await _cookie(videoA, 'new_context'), isNull);
  });

  test('tvPlayUrl omits the key but keeps the bound login owner when its access key is null', () async {
    final nullKey = _nullKeyAccount(378, session: 'video-null-key');
    final main = _account(379, session: 'main-owner');
    await Accounts.installCredentials(nullKey);
    await Accounts.installCredentials(main);
    Accounts.selectTemporarily(AccountType.main, main);
    await Accounts.set(AccountType.video, nullKey);
    expect(Accounts.get(AccountType.video), same(nullKey));

    final stateFuture = VideoHttp.tvPlayUrl(cid: 19, objectId: 30, playurlType: 1);
    final request = await adapter.nextRequest();
    expect(request.options.extra['account'], same(nullKey));
    expect(request.options.queryParameters.containsKey('access_key'), isFalse);
    expect(request.options.queryParameters.containsKey('mobile_access_key'), isFalse);
    expect(request.options.headers['x-bili-mid'], '378');
    expect(
      request.options.headers[HttpHeaders.cookieHeader],
      contains('SESSDATA=video-null-key'),
    );
    request.complete(
      body: const {'code': -1, 'message': 'fixture'},
      cookies: ['null_key=kept; Domain=.bilibili.com; Path=/'],
    );
    expect(await stateFuture, isA<Error>());
    expect(await _cookie(nullKey, 'null_key'), 'kept');
    expect(await _cookie(main, 'null_key'), isNull);
  });

  test('feedDislike keeps the gate owner when the recommend slot switches before binding', () async {
    final recommendA = _account(381, session: 'feed-a');
    final recommendB = _account(382, session: 'feed-b');
    await Accounts.installCredentials(recommendA);
    await Accounts.installCredentials(recommendB);
    Accounts.selectTemporarily(AccountType.recommend, recommendA);
    final barrier = installBarrier();

    final stateFuture = VideoHttp.feedDislike(goto: 'video', id: 81, reasonId: 1);
    await barrier.entered.future;
    Accounts.selectTemporarily(AccountType.recommend, recommendB);
    barrier.release();

    await expectPrebindAppOutcome(stateFuture, recommendA, 'feed-a', Api.feedDislike);
  });

  test('dislikeVideo keeps the gate owner when the main slot switches before binding', () async {
    final mainA = _account(383, session: 'main-gate-a');
    final mainB = _account(384, session: 'main-gate-b');
    await Accounts.installCredentials(mainA);
    await Accounts.installCredentials(mainB);
    Accounts.selectTemporarily(AccountType.main, mainA);
    final barrier = installBarrier();

    final stateFuture = VideoHttp.dislikeVideo(bvid: 'BV1xx411c7mD', type: true);
    await barrier.entered.future;
    Accounts.selectTemporarily(AccountType.main, mainB);
    barrier.release();

    await expectPrebindAppOutcome(
      stateFuture,
      mainA,
      'main-gate-a',
      Api.dislikeVideo,
      keyInBody: true,
    );
  });

  test('feedDislike cancels instead of sending after a pre-binding recommend replacement', () async {
    final recommend = _account(385, session: 'feed-replace');
    await Accounts.installCredentials(recommend);
    Accounts.selectTemporarily(AccountType.recommend, recommend);
    final barrier = installBarrier();

    final stateFuture = VideoHttp.feedDislike(goto: 'video', id: 82, reasonId: 2);
    await barrier.entered.future;
    final replacement = _account(385, session: 'feed-replacement');
    await Accounts.installCredentials(replacement);
    expect(Accounts.ownsCredentials(recommend), isFalse);
    barrier.release();

    final outcome = await settleOutcome(stateFuture);
    expect(
      outcome.fetched,
      isFalse,
      reason: 'a replaced pre-binding gate owner must cancel before any fetch',
    );
    expect(await stateFuture, isA<Error>());
    expect(adapter.fetchCount, 0);
  });

  test('a null-key installed recommend login still rejects the feed gate before sending', () async {
    final nullKey = _nullKeyAccount(386, session: 'recommend-null-key');
    final main = _account(387, session: 'main-owner');
    await Accounts.installCredentials(nullKey);
    await Accounts.installCredentials(main);
    Accounts.selectTemporarily(AccountType.main, main);
    Accounts.selectTemporarily(AccountType.recommend, nullKey);
    final state = await VideoHttp.feedDislike(goto: 'video', id: 3, reasonId: 3);
    expect(state, isA<Error>());
    expect((state as Error).errMsg, '请退出账号后重新登录');
    expect(adapter.fetchCount, 0);
  });

  test('feedDislikeCancel keeps the gate owner when the recommend slot switches before binding', () async {
    final recommendA = _account(388, session: 'cancel-a');
    final recommendB = _account(389, session: 'cancel-b');
    await Accounts.installCredentials(recommendA);
    await Accounts.installCredentials(recommendB);
    Accounts.selectTemporarily(AccountType.recommend, recommendA);
    final barrier = installBarrier();

    final stateFuture = VideoHttp.feedDislikeCancel(
      goto: 'video',
      id: 83,
      feedbackId: 4,
    );
    await barrier.entered.future;
    Accounts.selectTemporarily(AccountType.recommend, recommendB);
    barrier.release();

    await expectPrebindAppOutcome(
      stateFuture,
      recommendA,
      'cancel-a',
      Api.feedDislikeCancel,
    );
  });

  test('feedDislikeCancel cancels instead of sending after a pre-binding recommend replacement', () async {
    final recommend = _account(391, session: 'cancel-replace');
    await Accounts.installCredentials(recommend);
    Accounts.selectTemporarily(AccountType.recommend, recommend);
    final barrier = installBarrier();

    final stateFuture = VideoHttp.feedDislikeCancel(
      goto: 'video',
      id: 84,
      feedbackId: 5,
    );
    await barrier.entered.future;
    final replacement = _account(391, session: 'cancel-replacement');
    await Accounts.installCredentials(replacement);
    expect(Accounts.ownsCredentials(recommend), isFalse);
    barrier.release();

    final outcome = await settleOutcome(stateFuture);
    expect(
      outcome.fetched,
      isFalse,
      reason: 'a replaced pre-binding gate owner must cancel before any fetch',
    );
    expect(await stateFuture, isA<Error>());
    expect(adapter.fetchCount, 0);
  });

  test('a null-key installed recommend login still rejects the cancel gate before sending', () async {
    final nullKey = _nullKeyAccount(392, session: 'cancel-null-key');
    final main = _account(393, session: 'main-owner');
    await Accounts.installCredentials(nullKey);
    await Accounts.installCredentials(main);
    Accounts.selectTemporarily(AccountType.main, main);
    Accounts.selectTemporarily(AccountType.recommend, nullKey);
    final state = await VideoHttp.feedDislikeCancel(
      goto: 'video',
      id: 4,
      reasonId: 4,
    );
    expect(state, isA<Error>());
    expect((state as Error).errMsg, '请退出账号后重新登录');
    expect(adapter.fetchCount, 0);
  });

  test('a null-key installed main login still rejects the dislike gate before sending', () async {
    final nullKey = _nullKeyAccount(394, session: 'main-null-key');
    final video = _account(395, session: 'video-owner');
    await Accounts.installCredentials(nullKey);
    await Accounts.installCredentials(video);
    Accounts.selectTemporarily(AccountType.main, nullKey);
    Accounts.selectTemporarily(AccountType.video, video);
    final state = await VideoHttp.dislikeVideo(bvid: 'BV1xx411c7mD', type: true);
    expect(state, isA<Error>());
    expect((state as Error).errMsg, '请退出账号后重新登录');
    expect(adapter.fetchCount, 0);
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

/// Deterministically locates the phase between the Dio request chain start and
/// the AccountManager binding: added BEFORE the AccountManager, its onRequest
/// pauses handler.next until [release], so a slot switch while [entered] is
/// completed provably happens before the owner resolution.
class _BindingBarrierInterceptor extends Interceptor {
  final Completer<void> entered = Completer<void>();
  final Completer<void> _release = Completer<void>();

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (!entered.isCompleted) entered.complete();
    _release.future.then((_) => handler.next(options));
  }
}
