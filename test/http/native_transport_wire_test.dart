import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../utils/accounts/account_test_storage.dart';

/// Executes the real installed Request forced-H11 client against the same
/// synthetic server as Native. No adapter, decoder or status validator mock.
void main() {
  final base = Platform.environment['PILI_RAW_WIRE_BASE'];
  final output = Platform.environment['PILI_RAW_WIRE_OUTPUT'];
  test('actual Request H11 raw fields and receive-idle wire', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Flutter's widget binding installs a fixed-400 HttpClient globally. This
    // zone uses dart:io's real client without replacing Dio's production adapter.
    await HttpOverrides.runWithHttpOverrides(() async {
      expect(Uri.parse(base!).host, '127.0.0.1');
      final storage = await AccountTestStorage.open(replaceHTTPAdapter: false);
      final observations = <Map<String, Object?>>[];
      try {
        final fixtures = jsonDecode(await File('$output/fixtures.json').readAsString()) as List;
        for (final raw in fixtures) {
          final item = raw as Map<String, dynamic>;
          final name = item['id'] as String;
          final mode = item['mode'] as String;
          final token = CancelToken();
          final watch = Stopwatch()..start();
          Response<dynamic>? response;
          DioException? failure;
          final operation = Request.http11Dio.getUri<dynamic>(
            Uri.parse('$base/dart/$name'),
            options: Options(responseType: ResponseType.bytes, followRedirects: false),
            cancelToken: token,
            onReceiveProgress: mode == 'pending' ? (_, _) => token.cancel('fixture head/body arrived') : null,
          );
          if (mode == 'no-head') {
            for (var i = 0; i < 500; i++) {
              if (File('$output/seen-dart-$name').existsSync()) break;
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            token.cancel('fixture server recorded arrival before head');
          }
          try {
            response = await operation;
          } on DioException catch (error) {
            failure = error;
            response = error.response;
          }
          final body = response?.data is List<int> ? response!.data as List<int> : null;
          observations.add({
            'id': name, 'status': response?.statusCode,
            'cookieFields': response?.headers['set-cookie'] ?? <String>[],
            'bodyBase64': body == null ? null : base64Encode(body),
            'error': failure?.type.name, 'elapsedSeconds': watch.elapsedMicroseconds / 1000000,
          });
          if (mode == 'no-head' || mode == 'pending') {
            expect(failure?.type, DioExceptionType.cancel);
          } else if (mode == 'idle-timeout') {
            expect(failure?.type, DioExceptionType.receiveTimeout);
          } else if (mode == 'eof') {
            expect(failure, isNotNull);
          } else {
            expect(response?.statusCode, item['statusCode']);
            expect(body == null ? null : base64Encode(body), item['expectedBodyBase64']);
            expect(response?.headers['set-cookie'], item['wireValues']);
            if (mode == 'long-stream') expect(watch.elapsedMilliseconds, greaterThan(10000));
            if ((item['statusCode'] as int) >= 300) {
              expect(failure?.type, DioExceptionType.badResponse);
            } else {
              expect(failure, isNull);
            }
          }
        }
      } finally {
        await File('$output/dart-observations.json').writeAsString(const JsonEncoder.withIndent('  ').convert(observations));
        await storage.close();
      }
    }, _RealWireHttpOverrides());
  }, timeout: const Timeout(Duration(minutes: 3)), skip: base == null || output == null);
}

// Inherited createHttpClient delegates to dart:io's actual native implementation.
final class _RealWireHttpOverrides extends HttpOverrides {}
