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
  final gates = <String, Completer<int>>{};
  var requests = 0;
  final latency = NativeCDNLatency(probe: (url) {
    requests++;
    return (gates[url.host] = Completer<int>()).future;
  });
  final selected = latency.choose(urls);
  check(requests == 3, 'Aliases must share the same probe');
  gates['fast.example']!.complete(20);
  check(await selected.timeout(const Duration(seconds: 1)) == 'fast',
      'First usable result must start playback without waiting for slow probes');
  gates['failed.example']!.completeError(TimeoutException('test'));
  gates['origin.example']!.complete(200);
  await latency.test(urls);
  check(latency.bestSource(urls) == 'fast', 'Lowest measured latency wins');
  check(latency.measurements['failed']!.status == 'timeout', 'Timeout is not a usable source');
  check(latency.measurements['alias']!.milliseconds == 20, 'Alias shares result');
  await latency.choose(urls);
  check(requests == 3, 'Fresh cache avoids probing on every video');
  check(latency.bestSource({'fast': 'https://other.example/video'}) == null,
      'Changed host must not inherit an old measurement');
  latency.checkedAt = DateTime.now().subtract(const Duration(minutes: 4));
  check(latency.bestSource(urls) == null, 'Expired latency must not select a source');

  final failed = NativeCDNLatency(probe: (_) => Future.error(const HttpException('offline')));
  check(await failed.choose(urls) == null, 'All failures preserve default fallback');
  check(await failed.choose({'bad': 'http://['}) == null, 'Malformed URL must not hang startup');
  check(await failed.choose({}) == null, 'An empty candidate list must complete');

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  String? receivedRange;
  String? receivedQuery;
  final subscription = server.listen((request) async {
    receivedRange = request.headers.value(HttpHeaders.rangeHeader);
    receivedQuery = request.uri.query;
    if (request.uri.path == '/slow') {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    request.response.statusCode = request.uri.path == '/error' ? 403 : 206;
    request.response.headers.contentType = request.uri.path == '/html'
        ? ContentType.html : ContentType.binary;
    request.response.add([0]);
    await request.response.close();
  });
  Uri endpoint(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');
  try {
    check(await probeMediaLatency(endpoint('/video?sign=a%2Fb')) > 0,
        'Successful media response produces a positive latency');
    check(receivedRange == 'bytes=0-0', 'Probe must request only one byte');
    check(receivedQuery == 'sign=a%2Fb', 'Signed query must survive unchanged');
    for (final path in ['/error', '/html', '/slow']) {
      Object? failure;
      try {
        await probeMediaLatency(endpoint(path), timeout: const Duration(milliseconds: 80));
      } catch (error) { failure = error; }
      check(failure != null, '$path must never count as a successful source');
      if (path == '/slow') check(failure is TimeoutException, 'Slow probe must be bounded');
    }
  } finally {
    await subscription.cancel();
    await server.close(force: true);
  }
  print('PASS: CDN ranking, parallel startup, cache, fallback, range, signature and timeout checks');
}
