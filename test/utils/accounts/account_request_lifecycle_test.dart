import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

final _origin = Uri.parse('https://www.bilibili.com/github/account-fixture');
final _redirect = Uri.parse(
  'https://passport.bilibili.com/github/account-fixture',
);

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

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });

  setUp(() async {
    await storage.reset();
    adapter = _ControlledAdapter();
    dio = Dio(
      BaseOptions(responseType: ResponseType.plain, followRedirects: false),
    )
      ..httpClientAdapter = adapter
      ..interceptors.add(AccountManager());
  });

  tearDown(() => dio.close(force: true));
  tearDownAll(() => storage.close());

  Future<Response<String>> send(Account account) => dio.get<String>(
    _origin.toString(),
    options: Options(extra: {'account': account}),
  );

  Future<void> finish(
    Future<Response<String>> response,
    _PendingRequest request, {
    int status = 200,
    required List<String> cookies,
    Uri? location,
  }) async {
    // Install the error expectation before completing a non-2xx response.
    final result = status >= 200 && status < 300
        ? expectLater(response, completes)
        : expectLater(
            response,
            throwsA(
              isA<DioException>().having(
                (error) => error.response?.statusCode,
                'status code',
                status,
              ),
            ),
          );
    request.complete(status: status, cookies: cookies, location: location);
    await result;
  }

  for (final status in [200, 403, 302]) {
    test('status $status writes to A after selecting B', () async {
      final a = _account(101, session: 'account-a');
      final b = _account(202, session: 'account-b');
      await Accounts.installCredentials(a);
      await Accounts.installCredentials(b);
      await Accounts.set(AccountType.recommend, a);
      final stamp = Accounts.captureRequest(a)!;
      final response = send(a);
      final request = await adapter.nextRequest();
      expect(request.options.extra['account'], same(a));

      await Accounts.set(AccountType.recommend, b);
      expect(Accounts.get(AccountType.recommend), same(b));
      expect(Accounts.isCurrentRequest(stamp), isTrue);
      await finish(
        response,
        request,
        status: status,
        cookies: [
          'from_a=status-$status; Domain=.bilibili.com; Path=/',
          if (status == 302) 'redirect_host=from-a; Path=/',
        ],
        location: status == 302 ? _redirect : null,
      );

      expect(await _cookie(a, 'from_a'), 'status-$status');
      expect(await _cookie(b, 'from_a'), isNull);
      expect(Accounts.account.get('101'), same(a));
      expect(Accounts.account.get('202'), same(b));
      expect(await _cookie(b, 'SESSDATA'), 'account-b');
      if (status == 302) {
        // Host-only cookies need the redirect-location save as well as the
        // original-response save; a domain cookie would hide this regression.
        expect(await _cookie(a, 'redirect_host', uri: _redirect), 'from-a');
        expect(await _cookie(b, 'redirect_host', uri: _redirect), isNull);
      }
    });
  }

  test('both concurrent responses remain valid after a cookie revision', () async {
    final a = _account(101);
    await Accounts.installCredentials(a);
    final stamp = Accounts.captureRequest(a)!;
    final first = send(a);
    final firstRequest = await adapter.nextRequest();
    final second = send(a);
    final secondRequest = await adapter.nextRequest();
    final beforeCookie = Accounts.requestRevision;

    await finish(
      first,
      firstRequest,
      cookies: ['first_response=one; Domain=.bilibili.com; Path=/'],
    );
    expect(Accounts.requestRevision, greaterThan(beforeCookie));
    expect(Accounts.isCurrentRequest(stamp), isTrue);
    await finish(
      second,
      secondRequest,
      cookies: ['second_response=two; Domain=.bilibili.com; Path=/'],
    );

    expect(await _cookie(a, 'first_response'), 'one');
    expect(await _cookie(a, 'second_response'), 'two');
    expect(Accounts.isCurrentRequest(stamp), isTrue);
    expect(Accounts.account.get('101'), same(a));
  });

  test('RetryInterceptor redirect keeps A binding after selecting B', () async {
    dio.interceptors.insert(0, RetryInterceptor(dio, 1, 0));
    dio.options.followRedirects = true;
    final a = _account(101, session: 'account-a');
    final b = _account(202, session: 'account-b');
    await Accounts.installCredentials(a);
    await Accounts.installCredentials(b);
    await Accounts.set(AccountType.recommend, a);
    final response = send(a);
    final first = await adapter.nextRequest();
    await Accounts.set(AccountType.recommend, b);
    // RetryInterceptor consumes this 302 before AccountManager sees it.
    // Assert ownership of the final response only.
    first.complete(
      status: 302,
      cookies: ['intermediate=unasserted; Domain=.bilibili.com; Path=/'],
      location: _redirect,
    );
    final redirected = await adapter.nextRequest();
    expect(redirected.options, same(first.options));
    expect(redirected.options.uri, _redirect);
    expect(redirected.options.extra['account'], same(a));
    await finish(
      response,
      redirected,
      cookies: ['redirect_final=from-a; Domain=.bilibili.com; Path=/'],
    );
    expect(adapter.fetchCount, 2);
    expect(await _cookie(a, 'redirect_final'), 'from-a');
    expect(await _cookie(b, 'redirect_final'), isNull);
    expect(Accounts.get(AccountType.recommend), same(b));
  });

  test('overlapping Hive installs only activate the latest same-MID owner', () async {
    final old = _account(101, session: 'old');
    await Accounts.installCredentials(old);
    await Accounts.set(AccountType.recommend, old);
    final oldStamp = Accounts.captureRequest(old)!;
    final first = _account(101, session: 'first');
    final second = _account(101, session: 'second');
    final firstInstall = Accounts.installCredentials(first);
    final firstFailure = expectLater(firstInstall, throwsStateError);
    expect(Accounts.isCurrentRequest(oldStamp), isFalse);
    expect(Accounts.captureRequest(first), isNull);
    final secondInstall = Accounts.installCredentials(second);
    expect(Accounts.captureRequest(first), isNull);
    expect(Accounts.captureRequest(second), isNull);
    await Future.wait([firstFailure, secondInstall]);

    final newStamp = Accounts.captureRequest(second)!;
    expect(Accounts.isCurrentRequest(newStamp), isTrue);
    expect(Accounts.ownsCredentials(first), isFalse);
    expect(Accounts.account.get('101'), same(second));
    expect(Accounts.get(AccountType.recommend), same(second));
    await old.onChange();
    await first.onChange();
    await old.delete();
    await first.delete();
    expect(Accounts.account.get('101'), same(second));
    expect(Accounts.isCurrentRequest(newStamp), isTrue);
    expect(Accounts.isCurrentRequest(oldStamp), isFalse);
  });

  test('overlapping anonymous resets leave only the latest generation active', () async {
    final anonymous = AnonymousAccount();
    final oldStamp = Accounts.captureRequest(anonymous)!;
    final response = send(anonymous);
    final request = await adapter.nextRequest();
    final first = anonymous.delete();
    expect(Accounts.captureRequest(anonymous), isNull);
    final second = anonymous.delete();
    expect(Accounts.captureRequest(anonymous), isNull);
    await Future.wait([first, second]);
    final newStamp = Accounts.captureRequest(anonymous)!;
    expect(Accounts.isCurrentRequest(newStamp), isTrue);
    expect(Accounts.isCurrentRequest(oldStamp), isFalse);
    expect(anonymous.activated, isFalse);
    await finish(
      response,
      request,
      cookies: ['before_double_reset=stale; Domain=.bilibili.com; Path=/'],
    );
    expect(await _cookie(anonymous, 'before_double_reset'), isNull);
    expect(Accounts.isCurrentRequest(newStamp), isTrue);
  });

  test('same MID replacement rejects old response, onChange and delete', () async {
    final old = _account(101, session: 'old-credentials');
    await Accounts.installCredentials(old);
    await Accounts.set(AccountType.recommend, old);
    final oldStamp = Accounts.captureRequest(old)!;
    final response = send(old);
    final request = await adapter.nextRequest();
    final replacement = _account(101, session: 'new-credentials');
    expect(old == replacement, isTrue);
    expect(identical(old, replacement), isFalse);

    await Accounts.installCredentials(replacement);
    expect(Accounts.ownsCredentials(old), isFalse);
    expect(Accounts.ownsCredentials(replacement), isTrue);
    expect(Accounts.isCurrentRequest(oldStamp), isFalse);
    await finish(
      response,
      request,
      cookies: ['old_response=stale; Domain=.bilibili.com; Path=/'],
    );
    expect(await _cookie(old, 'old_response'), isNull);
    expect(await _cookie(replacement, 'old_response'), isNull);

    await old.cookieJar.saveFromResponse(_origin, [
      Cookie('SESSDATA', 'stale-on-change')..setBiliDomain(),
    ]);
    await old.onChange();
    expect(Accounts.account.get('101'), same(replacement));
    expect(await _cookie(replacement, 'SESSDATA'), 'new-credentials');

    await old.delete();
    expect(Accounts.account.get('101'), same(replacement));
    expect(Accounts.get(AccountType.recommend), same(replacement));
    expect(Accounts.ownsCredentials(replacement), isTrue);
    expect(Accounts.isCurrentRequest(Accounts.captureRequest(replacement)!), isTrue);
  });

  test('deleteAll with an old same-MID identity preserves the new slot', () async {
    final old = _account(101, session: 'old');
    final replacement = _account(101, session: 'new');
    await Accounts.installCredentials(old);
    await Accounts.set(AccountType.recommend, old);
    await Accounts.installCredentials(replacement);

    await Accounts.deleteAll({old});

    expect(Accounts.account.get('101'), same(replacement));
    expect(Accounts.get(AccountType.recommend), same(replacement));
    expect(Accounts.ownsCredentials(replacement), isTrue);
  });

  test('refresh registers Hive replacement and removes the old empty-type slot', () async {
    final old = _account(101, session: 'old');
    await Accounts.installCredentials(old);
    await Accounts.set(AccountType.recommend, old);
    final oldStamp = Accounts.captureRequest(old)!;
    final response = send(old);
    final request = await adapter.nextRequest();
    final replacement = _account(101, session: 'hive-replacement');

    await Accounts.account.put('101', replacement);
    expect(Accounts.captureRequest(replacement), isNull);
    await Accounts.refresh();
    final stamp = Accounts.captureRequest(replacement)!;
    expect(Accounts.isCurrentRequest(oldStamp), isFalse);
    expect(Accounts.get(AccountType.recommend), isA<AnonymousAccount>());
    expect(Accounts.ownsCredentials(replacement), isTrue);
    await Accounts.refresh();
    expect(Accounts.isCurrentRequest(stamp), isTrue);

    await finish(
      response,
      request,
      cookies: ['before_refresh=stale; Domain=.bilibili.com; Path=/'],
    );
    expect(await _cookie(old, 'before_refresh'), isNull);
    expect(await _cookie(replacement, 'before_refresh'), isNull);
    expect(Accounts.account.get('101'), same(replacement));
  });

  test('clear immediately revokes a stored but unselected request', () async {
    final a = _account(101);
    await Accounts.installCredentials(a);
    expect(Accounts.get(AccountType.recommend), isA<AnonymousAccount>());
    final stamp = Accounts.captureRequest(a)!;
    final anonymousStamp = Accounts.captureRequest(AnonymousAccount())!;
    final response = send(a);
    final request = await adapter.nextRequest();

    final clearing = Accounts.clear();
    expect(Accounts.isCurrentRequest(stamp), isFalse);
    expect(Accounts.isCurrentRequest(anonymousStamp), isFalse);
    await clearing;
    await finish(
      response,
      request,
      cookies: ['after_clear=stale; Domain=.bilibili.com; Path=/'],
    );

    expect(Accounts.account.isEmpty, isTrue);
    expect(await _cookie(a, 'after_clear'), isNull);
    expect(Accounts.captureRequest(a), isNull);
  });

  test('delete revokes before its asynchronous work completes', () async {
    final a = _account(101);
    await Accounts.installCredentials(a);
    final stamp = Accounts.captureRequest(a)!;
    final response = send(a);
    final request = await adapter.nextRequest();

    final deleting = a.delete();
    expect(Accounts.isCurrentRequest(stamp), isFalse);
    expect(Accounts.captureRequest(a), isNull);
    await finish(
      response,
      request,
      cookies: ['after_delete=stale; Domain=.bilibili.com; Path=/'],
    );
    await deleting;

    expect(Accounts.account.containsKey('101'), isFalse);
    expect(await _cookie(a, 'after_delete'), isNull);
  });

  test('anonymous reset disables capture and rejects the old generation', () async {
    final anonymous = AnonymousAccount();
    final stamp = Accounts.captureRequest(anonymous)!;
    final response = send(anonymous);
    final request = await adapter.nextRequest();
    final session = anonymous.grpcHeaders['x-bili-fawkes-req-bin'];

    final resetting = anonymous.delete();
    expect(Accounts.captureRequest(anonymous), isNull);
    expect(Accounts.isCurrentRequest(stamp), isFalse);
    await resetting;
    expect(AnonymousAccount(), same(anonymous));
    final newStamp = Accounts.captureRequest(anonymous)!;
    expect(newStamp, isNot(same(stamp)));
    expect(Accounts.isCurrentRequest(newStamp), isTrue);
    expect(anonymous.grpcHeaders['x-bili-fawkes-req-bin'], isNot(session));
    expect(await _cookie(anonymous, 'buvid3'), isNotNull);
    await finish(
      response,
      request,
      cookies: ['before_reset=stale; Domain=.bilibili.com; Path=/'],
    );
    expect(await _cookie(anonymous, 'before_reset'), isNull);
  });

  test('reusing RequestOptions cannot capture a generation after reset', () async {
    final anonymous = AnonymousAccount();
    final oldStamp = Accounts.captureRequest(anonymous)!;
    final options = RequestOptions(
      path: _origin.toString(),
      method: 'GET',
      responseType: ResponseType.plain,
      extra: {'account': anonymous},
    );
    final response = dio.fetch<String>(options);
    final request = await adapter.nextRequest();
    await anonymous.delete();
    expect(Accounts.isCurrentRequest(oldStamp), isFalse);
    expect(Accounts.captureRequest(anonymous), isNotNull);
    await finish(
      response,
      request,
      cookies: ['first_attempt=stale; Domain=.bilibili.com; Path=/'],
    );

    expect(adapter.fetchCount, 1);
    await expectLater(
      dio.fetch<String>(options),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );

    expect(adapter.fetchCount, 1);
    expect(await _cookie(anonymous, 'first_attempt'), isNull);
  });

  test('A to B to A increases selection revision without revoking A', () async {
    final a = _account(101);
    final b = _account(202);
    await Accounts.installCredentials(a);
    await Accounts.installCredentials(b);
    final stamp = Accounts.captureRequest(a)!;
    final before = Accounts.requestRevision;

    await Accounts.set(AccountType.recommend, a);
    final selectedA = Accounts.requestRevision;
    expect(selectedA, greaterThan(before));
    await Accounts.set(AccountType.recommend, b);
    final selectedB = Accounts.requestRevision;
    expect(selectedB, greaterThan(selectedA));
    await Accounts.set(AccountType.recommend, a);
    expect(Accounts.requestRevision, greaterThan(selectedB));

    expect(Accounts.get(AccountType.recommend), same(a));
    expect(Accounts.isCurrentRequest(stamp), isTrue);
    expect(a.type, contains(AccountType.recommend));
    expect(b.type, isNot(contains(AccountType.recommend)));
  });

  test('replacement keeps persistent types and temporary anonymous choice', () async {
    final old = _account(
      101,
      session: 'old',
      types: {AccountType.recommend, AccountType.heartbeat},
    );
    await Accounts.installCredentials(old);
    await Accounts.set(AccountType.recommend, old);
    Accounts.selectTemporarily(AccountType.heartbeat, old);
    final stamp = Accounts.captureRequest(old)!;
    final beforeTemporary = Accounts.requestRevision;
    final anonymous = AnonymousAccount();
    Accounts.selectTemporarily(AccountType.heartbeat, anonymous);
    expect(Accounts.requestRevision, greaterThan(beforeTemporary));
    expect(old.type, contains(AccountType.heartbeat));

    final replacement = _account(101, session: 'new');
    await Accounts.installCredentials(replacement);

    expect(replacement.type, {AccountType.recommend, AccountType.heartbeat});
    expect(Accounts.account.get('101'), same(replacement));
    expect(Accounts.get(AccountType.recommend), same(replacement));
    expect(Accounts.get(AccountType.heartbeat), same(anonymous));
    expect(Accounts.isCurrentRequest(stamp), isFalse);
    expect(Accounts.ownsCredentials(replacement), isTrue);
  });

  test('import uses input types and replaces slots from an old owner', () async {
    final old = _account(101, session: 'old');
    await Accounts.installCredentials(old);
    await Accounts.set(AccountType.recommend, old);
    final oldStamp = Accounts.captureRequest(old)!;
    final imported = _account(
      101,
      session: 'imported',
      types: {AccountType.video},
    );

    await Accounts.importCredentials({'101': imported});

    expect(Accounts.account.get('101'), same(imported));
    expect(imported.type, {AccountType.video});
    expect(Accounts.get(AccountType.video), same(imported));
    expect(Accounts.get(AccountType.recommend), isA<AnonymousAccount>());
    expect(Accounts.isCurrentRequest(oldStamp), isFalse);
    expect(Accounts.ownsCredentials(imported), isTrue);
  });

  test('import validates every key before replacing any credentials', () async {
    final old = _account(101, session: 'original');
    await Accounts.installCredentials(old);
    await Accounts.set(AccountType.recommend, old);
    final stamp = Accounts.captureRequest(old)!;
    final revision = Accounts.requestRevision;
    final replacement = _account(101, session: 'replacement');
    final invalid = _account(202, session: 'invalid-key');

    await expectLater(
      Accounts.importCredentials({'101': replacement, 'wrong-mid': invalid}),
      throwsArgumentError,
    );

    expect(Accounts.account.get('101'), same(old));
    expect(Accounts.account.length, 1);
    expect(Accounts.get(AccountType.recommend), same(old));
    expect(Accounts.isCurrentRequest(stamp), isTrue);
    expect(Accounts.requestRevision, revision);
    expect(Accounts.captureRequest(replacement), isNull);
    expect(Accounts.captureRequest(invalid), isNull);
  });

  test('NoAccount bypasses credential and cookie handling', () async {
    const account = NoAccount();
    expect(Accounts.captureRequest(account), isNull);
    final response = send(account);
    final request = await adapter.nextRequest();
    expect(request.options.headers[HttpHeaders.cookieHeader], isNull);

    await finish(
      response,
      request,
      cookies: ['without_account=ignored; Domain=.bilibili.com; Path=/'],
    );

    expect(Accounts.account.isEmpty, isTrue);
  });
}

class _PendingRequest {
  final RequestOptions options;
  final Completer<ResponseBody> response = Completer<ResponseBody>();

  _PendingRequest(this.options);

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
          if (location != null) HttpHeaders.locationHeader: [location.toString()],
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
