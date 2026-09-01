import 'dart:async';
import 'dart:io';

/// Downloads a bounded slice of a real media stream and returns KiB/s.
/// No account cookies are sent and the connection is closed after the sample.
Future<int> probeMediaDownloadSpeed(
  Uri url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 3),
  int sampleBytes = 1024 * 1024,
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  final watch = Stopwatch()..start();
  var downloaded = 0;
  try {
    final request = await client.getUrl(url).timeout(timeout);
    headers.forEach(request.headers.set);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${sampleBytes - 1}');
    request.maxRedirects = 3;
    final response = await request.close().timeout(timeout);
    final type = response.headers.contentType?.mimeType ?? '';
    if ((response.statusCode != 200 && response.statusCode != 206) ||
        type.contains('html') ||
        type.contains('json')) {
      throw const HttpException('Media source unavailable');
    }
    try {
      await for (final chunk in response.timeout(timeout)) {
        downloaded += chunk.length;
        if (downloaded >= sampleBytes || watch.elapsed >= timeout) break;
      }
    } on TimeoutException {
      if (downloaded == 0) rethrow;
    }
    if (downloaded == 0) throw const HttpException('Empty media response');
    final seconds = watch.elapsedMicroseconds / Duration.microsecondsPerSecond;
    return (downloaded / 1024 / seconds).round().clamp(1, 1 << 30);
  } finally {
    client.close(force: true);
  }
}

class NativeCDNMeasurement {
  const NativeCDNMeasurement(this.host, this.kilobytesPerSecond, this.status);
  final String host;
  final int? kilobytesPerSecond;
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
  Map<String, String> _pendingCandidates = {};

  bool get isFresh =>
      checkedAt != null && DateTime.now().difference(checkedAt!) < maxAge;

  String? bestSource(Map<String, String> candidates) {
    if (!isFresh) return null;
    String? best;
    int? fastest;
    for (final entry in candidates.entries) {
      final result = measurements[entry.key];
      final speed = result?.kilobytesPerSecond;
      if (speed != null &&
          result!.host == Uri.tryParse(entry.value)?.host &&
          (fastest == null || speed > fastest)) {
        fastest = speed;
        best = entry.key;
      }
    }
    return best;
  }

  Future<void> test(
    Map<String, String> candidates, {
    bool force = false,
  }) async {
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

  /// Returns a cached winner immediately and refreshes throughput in background.
  String? choose(Map<String, String> candidates) {
    final cached = bestSource(candidates);
    if (cached == null && _pending == null) _start(candidates);
    return cached;
  }

  bool _sameCandidates(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  void _start(Map<String, String> candidates) {
    if (candidates.isEmpty) return;
    _pendingCandidates = Map.of(candidates);
    measurements.clear();
    checkedAt = DateTime.now();
    _pending = (() async {
      for (final entry in candidates.entries) {
        final uri = Uri.tryParse(entry.value);
        try {
          if (uri == null || !uri.hasAuthority) {
            throw const FormatException('Invalid media URL');
          }
          // Sequential samples avoid the candidate streams competing for the
          // same connection bandwidth and skewing one another's result.
          final speed = await probe(uri);
          measurements[entry.key] = NativeCDNMeasurement(uri.host, speed, 'ok');
        } catch (error) {
          measurements[entry.key] = NativeCDNMeasurement(
            uri?.host ?? '',
            null,
            error is TimeoutException ? 'timeout' : 'unavailable',
          );
        }
      }
    })().whenComplete(() {
      _pending = null;
    });
  }
}
