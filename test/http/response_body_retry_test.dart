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

enum _BodyFault { truncated, gzip, brotli, json, trailingComma }

LoginAccount _account(int mid) => LoginAccount(
  BiliCookieJar.fromJson({'DedeUserID': '$mid'}), null, null,
)..activated = true;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Dio writes Cookie only after body framing and decoding succeed', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final storage = await AccountTestStorage.open();
      final owner = _account(77001), other = _account(77002);
      try {
        await Accounts.installCredentials(owner);
        await Accounts.installCredentials(other);
        for (final (name, fault, retryCount, completeStatus) in [
          ('recovered', _BodyFault.truncated, 2, 200),
          ('denied', _BodyFault.truncated, 2, 403),
          ('exhausted', _BodyFault.truncated, 2, null),
          ('zero', _BodyFault.truncated, 0, null),
          ('gzip', _BodyFault.gzip, 2, 200),
          ('brotli', _BodyFault.brotli, 2, 403),
          ('json', _BodyFault.json, 2, null),
          ('trailing-comma', _BodyFault.trailingComma, 1, 200),
        ]) {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final path = '/github/$name/';
          final url = Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: '${path}body');
          final requests = <({String? mid, String? cookie})>[];
          final errors = <(DioExceptionType, int?)>[];
          final dio = Dio(BaseOptions(receiveTimeout: const Duration(seconds: 2),
            responseDecoder: Request.dio.options.responseDecoder));
          dio.interceptors.addAll([
            InterceptorsWrapper(onError: (error, handler) {
              errors.add((error.type, error.response?.statusCode));
              handler.next(error);
            }),
            RetryInterceptor(dio, retryCount, 25),
            AccountManager(),
          ]);
          server.listen((request) async {
            requests.add((mid: request.headers.value('x-bili-mid'), cookie: request.headers.value('cookie')));
            if (name == 'recovered' && requests.length == 1) {
              await Accounts.set(AccountType.recommend, other);
            }
            final complete = completeStatus != null && requests.length == retryCount + 1;
            final body = complete ? '{}' : switch (fault) {
              _BodyFault.truncated => '{}',
              _BodyFault.gzip || _BodyFault.brotli => 'invalid encoding',
              _BodyFault.json => '{"code":',
              _BodyFault.trailingComma => '{"code":0,}',
            };
            final socket = await request.response.detachSocket(writeHeaders: false);
            final status = complete && completeStatus == 403 ? '403 Denied' : '200 OK';
            socket.write([
              'HTTP/1.1 $status',
              'Content-Type: application/json',
              if (!complete && fault == _BodyFault.gzip) 'Content-Encoding: gzip',
              if (!complete && fault == _BodyFault.brotli) 'Content-Encoding: br',
              'Connection: close',
              'Content-Length: ${!complete && fault == _BodyFault.truncated ? 100 : body.length}',
              'Set-Cookie: body_fixture=${complete ? 'complete' : 'failed'}; Path=$path',
              '', body,
            ].join('\r\n'));
            await socket.flush();
            await socket.close();
          });
          try {
            await Accounts.set(AccountType.recommend, owner);
            final revision = Accounts.requestRevision;
            Response<dynamic>? response;
            try {
              response = await dio.getUri<dynamic>(url, options: Options(extra: {'account': owner}));
            } on DioException catch (error) {
              response = error.response;
            }
            final saved = (await owner.cookieJar.loadForRequest(url)).where((cookie) => cookie.name == 'body_fixture');
            expect(response?.statusCode, completeStatus, reason: name);
            expect(requests, hasLength(retryCount + 1), reason: name);
            expect(requests.every((request) => request.mid == '77001' &&
                !(request.cookie?.contains('body_fixture=') ?? false)), isTrue, reason: name);
            expect(errors, [
              ...List.filled(retryCount + (completeStatus == null ? 1 : 0), (DioExceptionType.unknown, null)),
              if (completeStatus == 403) (DioExceptionType.badResponse, 403),
            ], reason: name);
            expect(Accounts.requestRevision - revision, (completeStatus == null ? 0 : 1) + (name == 'recovered' ? 1 : 0));
            expect(saved.map((cookie) => cookie.value), [if (completeStatus != null) 'complete'], reason: name);
            expect((await other.cookieJar.loadForRequest(url)).any((cookie) => cookie.name == 'body_fixture'), isFalse);
          } finally {
            dio.close(force: true);
            await server.close(force: true);
          }
        }
      } finally {
        await storage.close();
      }
    }, _LoopbackOverrides());
  });
}
