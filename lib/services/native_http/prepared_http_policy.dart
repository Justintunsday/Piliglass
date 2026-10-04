import 'package:PiliPlus/http/effective_http_policy.dart';
import 'package:dio/dio.dart';

/// Owned, versioned values for this composed request. No adapter, callback or
/// account reference crosses the bridge. A missing describer stays unknown.
final class PreparedHTTPPolicy {
  PreparedHTTPPolicy.capture({
    required EffectiveHTTPPolicySnapshot? effective,
    required RequestOptions request,
    required Map<String, String> headers,
  }) : values = Map.unmodifiable({
    'version': 1,
    'poolGeneration': effective?.poolGeneration ?? 0,
    'clientMode': effective?.http11Only == true ? 'http11' : 'main',
    'pool': _pool(effective?.pool),
    'retry': _retry(effective?.retry),
    'connectTimeoutMicroseconds': request.connectTimeout?.inMicroseconds,
    'receiveIdleTimeoutMicroseconds': request.receiveTimeout?.inMicroseconds,
    'sendTimeoutMicroseconds': request.sendTimeout?.inMicroseconds,
    'transformTimeoutMicroseconds': request.transformTimeout?.inMicroseconds,
    'receiveDataWhenStatusError': request.receiveDataWhenStatusError,
    'persistentConnection': request.persistentConnection,
    'followRedirects': request.followRedirects,
    'maxRedirects': request.maxRedirects,
    'acceptEncoding': headers['accept-encoding'],
    'responseType': request.responseType.name,
    'decoder': effective != null &&
        !effective.issues.contains(EffectiveHTTPPolicyIssue.decoderChanged)
        ? 'manualCompressionUTF8' : 'unknown',
    'issues': List<String>.unmodifiable(effective?.issues.map((issue) => issue.name) ??
        ['poolNotInstalled', 'retryNotDescribed', 'decoderChanged']),
  });

  final Map<String, Object?> values;

  bool sameAs(PreparedHTTPPolicy other) => _same(values, other.values);

  static Map<String, Object?>? _pool(EffectiveHTTPPoolConfiguration? pool) =>
      pool == null ? null : Map.unmodifiable({
        'http2Enabled': pool.http2Enabled,
        'idleTimeoutMicroseconds': pool.idleTimeout.inMicroseconds,
        'http11AcceptsBadCertificate': pool.http11AcceptsBadCertificate,
        'http2AcceptsBadCertificate': pool.http2AcceptsBadCertificate,
        'proxy': pool.proxyEnabled ? Map<String, Object?>.unmodifiable({
          'host': pool.proxyHost, 'port': pool.proxyPort,
        }) : null,
        'autoUncompress': pool.autoUncompress,
        'http2ALPN': List<String>.unmodifiable(pool.http2ALPN),
      });

  static Map<String, Object?>? _retry(EffectiveHTTPRetryPolicy? retry) =>
      retry == null ? null : Map.unmodifiable({
        'installed': retry.delayMilliseconds != null,
        'count': retry.count,
        'delayMilliseconds': retry.delayMilliseconds,
      });

  static bool _same(Object? left, Object? right) {
    if (left is Map && right is Map) {
      return left.length == right.length && left.entries.every(
        (entry) => right.containsKey(entry.key) && _same(entry.value, right[entry.key]),
      );
    }
    if (left is List && right is List) {
      return left.length == right.length &&
          Iterable<int>.generate(left.length).every((index) => _same(left[index], right[index]));
    }
    return left == right;
  }
}
