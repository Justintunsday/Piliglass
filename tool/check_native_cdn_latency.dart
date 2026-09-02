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
      return NativeCDNMeasurement(
        url.host,
        url.host == 'fast.example' ? 8 : 2,
        'ok',
      );
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
    throughput.measurements['alias']!.megabytesPerSecond == 8,
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
      request.response.statusCode = request.uri.path == '/error'
          ? 403
          : request.uri.path == '/html'
              ? 200
              : 200;
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
    final ok = await measureCdnDownloadSpeed(
      endpoint('/video?sign=a%2Fb'),
      timeout: const Duration(seconds: 5),
      maxBytes: 64,
    );
    check(
      ok.status == 'ok' && (ok.megabytesPerSecond ?? 0) > 0,
      'Successful full-stream response produces a positive MB/s sample',
    );
    check(
      receivedRange == null,
      'Measurement must fetch the whole stream without a Range slice',
    );
    check(receivedQuery == 'sign=a%2Fb', 'Signed query must survive unchanged');

    final unsupported = await measureCdnDownloadSpeed(
      endpoint('/error'),
      timeout: const Duration(seconds: 5),
      maxBytes: 64,
    );
    check(
      unsupported.status == 'unsupported',
      '4xx must surface as an unsupported CDN, not a speed',
    );

    final slow = await measureCdnDownloadSpeed(
      endpoint('/slow'),
      timeout: const Duration(milliseconds: 80),
      maxBytes: 64,
    );
    check(
      slow.status == 'timeout',
      'Slow overflow must surface as a bounded timeout',
    );

    final html = await measureCdnDownloadSpeed(
      endpoint('/html'),
      timeout: const Duration(seconds: 5),
      maxBytes: 64,
    );
    // The original dialog measures any served stream body; a 200 HTML page
    // still counts as a response but never happens for real playurls.
    check(html.status == 'ok', 'Served body measures as-is');
  } finally {
    await subscription.cancel();
    await server.close(force: true);
  }
  print(
    'PASS: CDN MB/s ranking, cache, fallback, unsupported, timeout and full-stream checks',
  );
}
