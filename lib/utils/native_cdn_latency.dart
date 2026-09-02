import 'dart:async';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:dio/dio.dart';

/// Measures a real CDN stream the same way the original PiliPlus project's
/// CDN settings dialog does, so both front-ends report comparable numbers:
///
/// - whole-file GET (no Range), streaming receive progress
/// - settle at 8 MiB downloaded or 15 s soft timeout
///   (a settling sample that produced nothing counts as a timeout)
/// - speed = downloaded bytes / elapsed microseconds => MB/s
///
/// Bilibili's playurls are tiny segments, so the 8 MiB ceiling is normally
/// reached almost immediately; the timeout covers slow or throttled edges.
Future<NativeCDNMeasurement> measureCdnDownloadSpeed(
  Uri url, {
  Map<String, String> headers = const {
    'user-agent': BrowserUa.pc,
    'referer': HttpString.baseUrl,
  },
  int maxBytes = 8 * 1024 * 1024,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final host = url.host;
  final dio = Dio(
    BaseOptions(
      connectTimeout: timeout,
      receiveTimeout: timeout,
    ),
  )..options.headers = headers;
  final cancelToken = CancelToken();
  final start = DateTime.now().microsecondsSinceEpoch;
  var downloaded = 0;
  var settled = false;
  NativeCDNMeasurement? measurement;

  void settle(double? megabytesPerSecond, String status, {String? message}) {
    if (settled || cancelToken.isCancelled) return;
    settled = true;
    measurement = NativeCDNMeasurement(
      host,
      megabytesPerSecond,
      status,
      message: message,
    );
    cancelToken.cancel();
  }

  try {
    await dio.get(
      url.toString(),
      cancelToken: cancelToken,
      options: Options(responseType: ResponseType.bytes),
      onReceiveProgress: (count, total) {
        downloaded += count;
        final duration = DateTime.now().microsecondsSinceEpoch - start;
        if (duration > timeout.inMicroseconds) {
          if (downloaded > 0) {
            // Original behavior: report the partial sample on timeout.
            settle(downloaded / duration, 'ok');
          } else {
            settle(null, 'timeout');
          }
        } else if (downloaded >= maxBytes) {
          settle(downloaded / duration, 'ok');
        }
      },
    );
    // Response finished before the inbound window was reached.
    if (measurement == null) {
      final duration = DateTime.now().microsecondsSinceEpoch - start;
      if (downloaded > 0 && duration > 0) {
        settle(downloaded / duration, 'ok');
      }
    }
  } on DioException catch (error) {
    if (measurement == null) {
      // The original dialog surfaces 4xx as "此视频可能无法替换为该CDN".
      final statusCode = error.response?.statusCode;
      if (statusCode != null && statusCode >= 400 && statusCode < 500) {
        settle(null, 'unsupported', message: '此视频可能无法替换为该CDN');
      } else if (error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.connectionTimeout) {
        if (downloaded > 0 && !settled) {
          settle(downloaded / (DateTime.now().microsecondsSinceEpoch - start), 'ok');
        } else if (!settled) {
          settle(null, 'timeout');
        }
      } else if (!settled) {
        settle(null, 'unavailable');
      }
    }
  } catch (_) {
    if (!settled) settle(null, 'unavailable');
  } finally {
    if (!cancelToken.isCancelled) cancelToken.cancel();
    dio.close(force: true);
  }
  return measurement ??
      NativeCDNMeasurement(host, null, 'unavailable');
}

class NativeCDNMeasurement {
  const NativeCDNMeasurement(
    this.host,
    this.megabytesPerSecond,
    this.status, {
    this.message,
  });

  final String host;

  /// bytes/µs == MB/s, same formula as the original settings dialog.
  final double? megabytesPerSecond;

  /// ok | timeout | unavailable | unsupported
  final String status;

  /// Optional user-facing reason, e.g. the original "此视频无法替换" case.
  final String? message;
}

/// Keeps a short-lived, in-memory ranking. Signed stream URLs are never saved.
class NativeCDNLatency {
  NativeCDNLatency({
    required this.probe,
    this.maxAge = const Duration(minutes: 3),
  });

  final Future<NativeCDNMeasurement> Function(Uri) probe;
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
    double? fastest;
    for (final entry in candidates.entries) {
      final speed = measurements[entry.key]?.megabytesPerSecond;
      final result = measurements[entry.key];
      if (speed != null &&
          result!.status == 'ok' &&
          result.host == Uri.tryParse(entry.value)?.host &&
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
    _pending =
        (() async {
          // CDNs may share a signed URL; probe each distinct URL only once.
          final probes = <String, Future<NativeCDNMeasurement>>{};
          for (final entry in candidates.entries) {
            // Sequential samples match the original dialog and avoid the
            // candidate streams competing for the same connection bandwidth.
            final uri = Uri.tryParse(entry.value);
            try {
              if (uri == null || !uri.hasAuthority) {
                throw const FormatException('Invalid media URL');
              }
              final result = await probes.putIfAbsent(
                entry.value,
                () => probe(uri),
              );
              measurements[entry.key] = result;
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
