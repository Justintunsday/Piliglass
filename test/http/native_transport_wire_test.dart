import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../utils/accounts/account_test_storage.dart';

/// Executes the real installed Request forced-H11 client against the same
/// synthetic server as Native. No adapter, decoder or status validator mock.
void main() {
  final base = Platform.environment['PILI_RAW_WIRE_BASE'];
  final output = Platform.environment['PILI_RAW_WIRE_OUTPUT'];
  final refused = Platform.environment['PILI_RAW_REFUSED_PORT'];
  final tlsStall = Platform.environment['PILI_RAW_TLS_STALL_PORT'];
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
          final redirectLimit = item['redirectLimit'] as int?;
          final url = Uri.parse('$base/dart/$name');
          final token = CancelToken();
          final watch = Stopwatch()..start();
          Response<dynamic>? response;
          DioException? failure;
          final operation = Request.http11Dio.getUri<dynamic>(
            url,
            options: Options(
              responseType: ResponseType.bytes,
              followRedirects: redirectLimit != null,
              maxRedirects: redirectLimit,
              headers: redirectLimit == null ? null : {
                HttpHeaders.cookieHeader: 'wire=synthetic',
                HttpHeaders.authorizationHeader: 'Bearer synthetic',
              },
            ),
            cancelToken: token,
            onReceiveProgress: mode == 'pending' ? (_, _) => token.cancel('fixture head/body arrived') : null,
          );
          if (mode == 'no-head' || mode == 'cancel-redirect') {
            final marker = File('$output/seen-dart-$name');
            for (var i = 0; i < 500; i++) {
              if (marker.existsSync()) break;
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            expect(marker.existsSync(), isTrue, reason: name);
            token.cancel('fixture server reached the cancellation point');
          }
          try {
            response = await operation;
          } on DioException catch (error) {
            failure = error;
            response = error.response;
          }
          final body = response?.data is List<int> ? response!.data as List<int> : null;
          final terminalUrl = response?.redirects.fold<Uri>(
            url,
            (source, hop) => source.resolveUri(hop.location),
          );
          final cookieScopeUrl = response == null ? null : url.resolveUri(response.realUri);
          observations.add({
            'id': name, 'status': response?.statusCode,
            'cookieFields': response?.headers['set-cookie'] ?? <String>[],
            'locationFields': response?.headers['location'] ?? <String>[],
            'bodyBase64': body == null ? null : base64Encode(body),
            'error': failure?.type.name, 'elapsedSeconds': watch.elapsedMicroseconds / 1000000,
            'terminalURL': terminalUrl?.toString(),
            'legacyCookieURL': cookieScopeUrl?.toString(),
          });
          if (item['locationValues'] case final List<dynamic> locations) {
            expect(response?.headers['location'], locations, reason: name);
          }
          if (redirectLimit != null) {
            expect(failure?.type.name, item['dartError'], reason: name);
            expect(response?.statusCode, item['statusCode'], reason: name);
            expect(response?.headers['set-cookie'] ?? [], item['wireValues'], reason: name);
            expect(body == null ? null : base64Encode(body), item['expectedBodyBase64'], reason: name);
            if (terminalUrl != null) {
              final targets = item['dartTargets'] as List<dynamic>;
              final last = Uri.parse('/dart/${targets.last}');
              final scope = Uri.parse('/dart/${item['legacyCookieTarget']}');
              expect(response!.redirects, hasLength(targets.length - 1), reason: name);
              expect(terminalUrl.path, last.path, reason: name);
              expect(terminalUrl.query, last.query, reason: name);
              expect(cookieScopeUrl!.path, scope.path, reason: name);
              expect(cookieScopeUrl.query, scope.query, reason: name);
              if (item['redirectLocations'] case final List<dynamic> locations) {
                expect(response.redirects.map((hop) => hop.location.toString()), locations, reason: name);
              }
            }
            continue;
          }
          if (item['dartRetry'] case final Map<String, dynamic> retry when item['statusCode'] == null) {
            expect(failure?.type.name, retry['error'], reason: name);
            expect(response, isNull, reason: name);
          } else if (mode == 'no-head' || mode == 'pending') {
            expect(failure?.type, DioExceptionType.cancel);
          } else if (mode == 'idle-timeout') {
            expect(failure?.type, DioExceptionType.receiveTimeout);
          } else if (mode == 'eof' || mode == 'chunked-eof') {
            expect(failure?.type, DioExceptionType.unknown, reason: name);
            expect(response, isNull, reason: name);
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

  test('installed retry waits 500 ms then 1000 ms after real refused connections', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final observation = await _observeRetry(Uri.parse('https://127.0.0.1:$refused/fixture'),
        expectedError: 'connectionError', attempts: 3, delay: 500);
      await File('$output/dart-initial-retry.json').writeAsString(jsonEncode(observation));
    }, _RealWireHttpOverrides());
  }, skip: refused == null || output == null);

  test('installed retry observes the actual H1 and TLS failure kinds on loopback', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixtures = jsonDecode(await File('$output/fixtures.json').readAsString()) as List<dynamic>;
      final observations = <Map<String, Object?>>[];
      const deadline = Duration(milliseconds: 600);
      for (final fixture in fixtures.cast<Map<String, dynamic>>()) {
        if (fixture['dartRetry'] case final Map<String, dynamic> retry) {
          final id = fixture['id'] as String;
          observations.add({'id': id, ...await _observeRetry(Uri.parse('$base/dart/$id'),
            expectedError: retry['error'] as String, attempts: retry['attempts'] as int, delay: 25,
            redirectLimit: fixture['redirectLimit'] as int?, timeout: deadline)});
        }
      }
      expect(observations, hasLength(7));
      observations.add({'id': 'tls-stall', ...await _observeRetry(Uri.parse('https://127.0.0.1:$tlsStall/fixture'),
        expectedError: 'connectionTimeout', attempts: 3, delay: 25, timeout: deadline)});
      await File('$output/dart-network-retry.json').writeAsString(jsonEncode(observations));
    }, _RealWireHttpOverrides());
  }, skip: base == null || output == null || tlsStall == null);
}

Future<Map<String, Object?>> _observeRetry(Uri url, {
  required String expectedError, required int attempts, required int delay, int? redirectLimit, Duration? timeout,
}) async {
  expect(url.host, '127.0.0.1');
  final dio = Dio(BaseOptions(responseType: ResponseType.bytes, connectTimeout: timeout, receiveTimeout: timeout));
  final timer = Stopwatch()..start();
  final starts = <int>[];
  final failures = <int>[];
  final types = <String>[];
  var attachedResponse = false;
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      starts.add(timer.elapsedMilliseconds);
      handler.next(options);
    },
    onError: (error, handler) {
      failures.add(timer.elapsedMilliseconds);
      types.add(error.type.name);
      attachedResponse = attachedResponse || error.response != null;
      handler.next(error);
    },
  ));
  dio.interceptors.add(RetryInterceptor(dio, 2, delay));
  try {
    await expectLater(dio.getUri<List<int>>(url, options: Options(
      followRedirects: redirectLimit != null, maxRedirects: redirectLimit, headers: {'X-Wire-Retry': '1'},
    )), throwsA(isA<DioException>().having((error) => error.type.name, 'type', expectedError)));
    expect(starts, hasLength(attempts), reason: url.path);
    expect(types, List.filled(attempts, expectedError), reason: url.path);
    expect(attachedResponse, isFalse, reason: url.path);
    final waits = [for (var i = 1; i < attempts; i++) starts[i] - failures[i - 1]];
    for (var i = 0; i < waits.length; i++) {
      expect(waits[i], greaterThanOrEqualTo(delay * (i + 1) - 10), reason: url.path);
    }
    return {'attempts': starts.length, 'errorKinds': types, 'backoffMilliseconds': waits};
  } finally {
    dio.close(force: true);
  }
}

// Inherited createHttpClient delegates to dart:io's actual native implementation.
final class _RealWireHttpOverrides extends HttpOverrides {}
