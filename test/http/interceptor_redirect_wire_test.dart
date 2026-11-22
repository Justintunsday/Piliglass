import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../utils/accounts/account_test_storage.dart';

final class _LoopbackOverrides extends HttpOverrides {}

LoginAccount _account(int mid) => LoginAccount(
  BiliCookieJar.fromJson({'DedeUserID': '$mid'}), null, null,
)..activated = true;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Dio reissues from its current options and unwinds error Cookie writes', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final storage = await AccountTestStorage.open();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = Uri.parse('http://127.0.0.1:${server.port}');
      final owner = _account(76001), other = _account(76002);
      final dio = Dio(BaseOptions(baseUrl: '$base', maxRedirects: 2,
        responseDecoder: Request.dio.options.responseDecoder));
      dio.interceptors.addAll([RetryInterceptor(dio, 0, 500), AccountManager()]);
      final seen = <({String target, String? cookie, String? mid})>[];
      server.listen((request) async {
        final url = request.uri;
        seen.add((target: '$url', cookie: request.headers.value('cookie'), mid: request.headers.value('x-bili-mid')));
        final mode = url.pathSegments[1];
        final response = request.response;
        response.headers.contentType = ContentType.json;
        var body = '{}';
        switch (url.pathSegments.last) {
          case 'start':
            response.statusCode = mode == 'exhausted' ? 300 : 302;
            response.headers.add('location', mode == 'exhausted' ? 'alpha/next?step=1' : 'nested/first?auto=1');
          case 'first':
            response.statusCode = 300;
            response.headers.add('location', 'next/target?step=1');
            response.headers.add('set-cookie', 'intermediate=ignored; Path=/');
            if (mode == 'success') await Accounts.set(AccountType.recommend, other);
            if (mode == 'corrupt') body = 'invalid JSON';
          case 'target':
            response.statusCode = 307;
            response.headers.add('location', 'last/response?auto=2');
          case 'next':
            response.statusCode = 300;
            response.headers.add('location', 'beta/last?step=2');
          case 'last':
            response.statusCode = 300;
            response.headers.add('location', 'extra/scope');
            response.headers.add('set-cookie', 'terminal=exhausted');
          case 'response':
            response.statusCode = mode == 'success' ? 200 : 403;
            response.headers.add('set-cookie', 'terminal=$mode');
          default:
            response.statusCode = 404;
        }
        response.write(body);
        await response.close();
      });
      try {
        await Accounts.installCredentials(owner);
        await Accounts.installCredentials(other);
        for (final mode in ['success', 'denied', 'exhausted', 'corrupt']) {
          await Accounts.set(AccountType.recommend, owner);
          final prefix = '/github/$mode';
          final first = '$prefix/start';
          await owner.cookieJar.saveFromResponse(base.resolve(first), [
            Cookie('original', mode)..path = '$prefix/',
            Cookie('scoped', mode)..path = '$prefix/next/',
          ]);
          seen.clear();
          final revision = Accounts.requestRevision;
          Response<dynamic>? result;
          DioExceptionType? failure;
          try {
            result = await dio.get<dynamic>(first, queryParameters: {'limit': 10},
              options: Options(extra: {'account': owner}));
          } on DioException catch (error) {
            result = error.response;
            failure = error.type;
          }
          expect(seen.first.target, '$first?limit=10');
          expect(seen.every((event) => event.mid == '76001'), isTrue);
          expect(seen.any((event) => event.cookie?.contains('intermediate=') ?? false), isFalse);
          if (mode == 'exhausted') {
            expect(seen.map((event) => event.target), [
              '$first?limit=10', '$prefix/alpha/next?step=1&limit=10', '$prefix/alpha/beta/last?step=2&limit=10',
            ]);
            expect(result?.requestOptions.maxRedirects, 0);
            expect(result?.statusCode, 300);
            expect(Accounts.requestRevision - revision, 6);
          } else if (mode == 'corrupt') {
            expect(seen.map((event) => event.target), ['$first?limit=10', '$prefix/nested/first?auto=1']);
            expect(failure, DioExceptionType.unknown);
            expect(result, isNull);
            expect(Accounts.requestRevision, revision);
          } else {
            expect(seen.map((event) => event.target), [
              '$first?limit=10', '$prefix/nested/first?auto=1',
              '$prefix/next/target?step=1&limit=10', '$prefix/next/last/response?auto=2',
            ]);
            expect(seen[2].cookie, 'original=$mode; scoped=$mode; original=$mode');
            expect(result?.requestOptions.maxRedirects, 1);
            expect(result?.statusCode, mode == 'success' ? 200 : 403);
            expect(Accounts.requestRevision - revision, 2); // One selection change or two error writes.
          }
        }
        expect(other.cookieJar.hostCookies, isEmpty);
      } finally {
        dio.close(force: true);
        await server.close(force: true);
        await storage.close();
      }
    }, _LoopbackOverrides());
  });
}
