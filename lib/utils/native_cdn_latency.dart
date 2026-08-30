import 'dart:async';
import 'dart:io';

/// Measures a real media request's time to first byte, including DNS and TLS.
/// No account cookies are sent. A range request and early close limit traffic.
Future<int> probeMediaLatency(
  Uri url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(milliseconds: 1200),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  final watch = Stopwatch()..start();
  try {
    return await (() async {
      final request = await client.getUrl(url);
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      request.maxRedirects = 3;
      final response = await request.close();
      final type = response.headers.contentType?.mimeType ?? '';
      if ((response.statusCode != 200 && response.statusCode != 206) ||
          type.contains('html') || type.contains('json')) {
        throw const HttpException('Media source unavailable');
      }
      final first = await response.first;
      if (first.isEmpty) throw const HttpException('Empty media response');
      return watch.elapsedMilliseconds.clamp(1, 60000);
    })().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

class NativeCDNMeasurement {
  const NativeCDNMeasurement(this.host, this.milliseconds, this.status);
  final String host;
  final int? milliseconds;
  final String status;
}

/// Keeps a short-lived, in-memory ranking. Signed stream URLs are never saved.
class NativeCDNLatency {
  NativeCDNLatency({
    required this.probe,
    this.maxAge = const Duration(minutes: 3),
  });

  final Future<int> Function(Uri) probe;
  final Duration maxAge;
  final Map<String, NativeCDNMeasurement> measurements = {};
  DateTime? checkedAt;
  Future<void>? _pending;
  Future<String?>? _firstReady;
  Map<String, String> _pendingCandidates = {};

  bool get isFresh => checkedAt != null &&
      DateTime.now().difference(checkedAt!) < maxAge;

  String? bestSource(Map<String, String> candidates) {
    if (!isFresh) return null;
    String? best;
    int? lowest;
    for (final entry in candidates.entries) {
      final result = measurements[entry.key];
      final ms = result?.milliseconds;
      if (ms != null && result!.host == Uri.tryParse(entry.value)?.host &&
          (lowest == null || ms < lowest)) {
        lowest = ms;
        best = entry.key;
      }
    }
    return best;
  }

  Future<void> test(Map<String, String> candidates, {bool force = false}) async {
    if (_pending != null) {
      await _pending;
      // A newer video may have different signed URLs/hosts. Don't apply an
      // unrelated in-flight sample to it after the first test completes.
      if (_sameCandidates(candidates, _pendingCandidates)) return;
    }
    if (!force && bestSource(candidates) != null) return;
    _start(candidates);
    await _pending;
  }

  Future<String?> choose(Map<String, String> candidates) async {
    final cached = bestSource(candidates);
    if (cached != null) return cached;
    if (_pending != null && !_sameCandidates(candidates, _pendingCandidates)) {
      // Don't make a new video's startup wait for an older sample.
      return null;
    }
    if (_pending == null) _start(candidates);
    await _firstReady;
    return bestSource(candidates);
  }

  bool _sameCandidates(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  void _start(Map<String, String> candidates) {
    _pendingCandidates = Map.of(candidates);
    measurements.clear();
    checkedAt = DateTime.now();
    final first = Completer<String?>();
    _firstReady = first.future;
    final requests = <String, Future<int>>{};
    _pending = Future.wait(candidates.entries.map((entry) async {
      final uri = Uri.tryParse(entry.value);
      try {
        if (uri == null || !uri.hasAuthority) {
          throw const FormatException('Invalid media URL');
        }
        // Aliases pointing at the same URL share a single network probe.
        final ms = await requests.putIfAbsent(entry.value, () => probe(uri));
        measurements[entry.key] = NativeCDNMeasurement(uri.host, ms, 'ok');
        if (!first.isCompleted) first.complete(entry.key);
      } catch (error) {
        measurements[entry.key] = NativeCDNMeasurement(
          uri?.host ?? '', null, error is TimeoutException ? 'timeout' : 'unavailable',
        );
      }
    })).then((_) {
      if (!first.isCompleted) first.complete(null);
    }).whenComplete(() { _pending = null; });
  }
}
