import 'dart:async';
import 'dart:io';

import '../lib/utils/native_cdn_latency.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  const urls = {
    'origin': 'https://origin.example/video?sign=a%2Fb',
    'fast': 'https://fast.example/video?sign=a%2Fb',
    'alias': 'https://fast.example/video?sign=a%2Fb',
    'failed': 'https://failed.example/video',
  };
  var requests = 0;
  final throughput = NativeCDNLatency(
    probe: (url) async {
      requests++;
      if (url.host == 'failed.example') throw TimeoutException('test');
      return url.host == 'fast.example' ? 800 : 200;
    },
  );
  await throughput.test(urls, force: true);
  check(requests == 3, 'Aliases must share the same probe');
  check(throughput.choose(urls) == 'fast', 'Fastest measured download wins');
  check(
    throughput.measurements['failed']!.status == 'timeout',
    'Timeout is not a usable source',
  );
  check(
    throughput.measurements['alias']!.kilobytesPerSecond == 800,
    'Alias shares result',
  );
  throughput.choose(urls);
  check(requests == 3, 'Fresh cache avoids probing on every video');
  check(
    throughput.bestSource({'fast': 'https://other.example/video'}) == null,
    'Changed host must not inherit an old measurement',
  );
  throughput.checkedAt = DateTime.now().subtract(const Duration(minutes: 4));
  check(
    throughput.bestSource(urls) == null,
    'Expired result must not select a source',
  );

  final failed = NativeCDNLatency(
    probe: (_) => Future.error(const HttpException('offline')),
  );
  await failed.test(urls);
  check(failed.choose(urls) == null, 'All failures preserve default fallback');
  await failed.test({'bad': 'http://['});
  check(
    failed.choose({'bad': 'http://['}) == null,
    'Malformed URL must not hang startup',
  );
  check(failed.choose({}) == null, 'An empty candidate list must complete');

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  String? receivedRange;
  String? receivedQuery;
  final subscription = server.listen((request) async {
    try {
      receivedRange = request.headers.value(HttpHeaders.rangeHeader);
      receivedQuery = request.uri.query;
      if (request.uri.path == '/slow') {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      request.response.statusCode = request.uri.path == '/error' ? 403 : 206;
      request.response.headers.contentType = request.uri.path == '/html'
          ? ContentType.html
          : ContentType.binary;
      request.response.add([0]);
      await request.response.close();
    } on SocketException {
      // The timeout case deliberately aborts the client before we reply.
    } on HttpException {
      // A disconnected response can also surface as an HTTP exception.
    }
  });
  Uri endpoint(String path) =>
      Uri.parse('http://127.0.0.1:${server.port}$path');
  try {
    check(
      await probeMediaDownloadSpeed(endpoint('/video?sign=a%2Fb')) > 0,
      'Successful media response produces a positive download speed',
    );
    check(
      receivedRange == 'bytes=0-1048575',
      'Probe must request a bounded media slice',
    );
    check(receivedQuery == 'sign=a%2Fb', 'Signed query must survive unchanged');
    for (final path in ['/error', '/html', '/slow']) {
      Object? failure;
      try {
        await probeMediaDownloadSpeed(
          endpoint(path),
          timeout: const Duration(milliseconds: 80),
        );
      } catch (error) {
        failure = error;
      }
      check(failure != null, '$path must never count as a successful source');
      if (path == '/slow')
        check(failure is TimeoutException, 'Slow probe must be bounded');
    }
  } finally {
    await subscription.cancel();
    await server.close(force: true);
  }
  print(
    'PASS: CDN throughput ranking, cache, fallback, range, signature and timeout checks',
  );
}
