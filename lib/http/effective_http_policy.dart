import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';

/// Values captured by the same factory that creates the actual adapters.
/// Proxy values stay in memory; this is not a diagnostics/credential export.
final class EffectiveHTTPPoolConfiguration {
  const EffectiveHTTPPoolConfiguration({
    required this.http2Enabled,
    required this.idleTimeout,
    required this.http11AcceptsBadCertificate,
    required this.http2AcceptsBadCertificate,
    this.proxyHost,
    this.proxyPort,
  });

  final bool http2Enabled;
  final Duration idleTimeout;
  final bool http11AcceptsBadCertificate;
  final bool? http2AcceptsBadCertificate;
  final String? proxyHost;
  final int? proxyPort;
  bool get proxyEnabled => proxyHost != null && proxyPort != null;
  bool get autoUncompress => false;
  // ConnectionManager's pinned default advertises only h2. Its adapter can
  // still fall back to HTTP/1.1; this is not an ['h2', 'http/1.1'] ALPN claim.
  List<String> get http2ALPN => http2Enabled ? const ['h2'] : const [];
}

final class EffectiveHTTPRetryPolicy {
  const EffectiveHTTPRetryPolicy(this.count, this.delayMilliseconds);

  final int count;
  final int? delayMilliseconds; // null means no RetryInterceptor installed.
}

enum EffectiveHTTPPolicyIssue {
  poolNotInstalled,
  poolInstallationFailed,
  adapterChanged,
  http11FactoryChanged,
  connectionManagerChanged,
  fallbackAdapterChanged,
  fallbackClientChanged,
  retryNotDescribed,
  decoderChanged,
  acceptEncodingNotDescribed,
}

/// Immutable description, not permission to send a Native request. Endpoint
/// Options, account leases, raw fields and transport parity are later gates.
final class EffectiveHTTPPolicySnapshot {
  EffectiveHTTPPolicySnapshot({
    required this.poolGeneration,
    required this.http11Only,
    required this.pool,
    required this.retry,
    required this.connectTimeout,
    required this.receiveIdleTimeout,
    required this.sendTimeout,
    required this.persistentConnection,
    required this.followRedirects,
    required this.maxRedirects,
    required this.acceptEncoding,
    required this.responseType,
    required Iterable<EffectiveHTTPPolicyIssue> issues,
  }) : issues = List.unmodifiable(issues);

  final int poolGeneration;
  final bool http11Only;
  final EffectiveHTTPPoolConfiguration? pool;
  final EffectiveHTTPRetryPolicy? retry;
  final Duration? connectTimeout;
  final Duration? receiveIdleTimeout;
  final Duration? sendTimeout;
  final bool persistentConnection;
  final bool followRedirects;
  final int maxRedirects;
  final String? acceptEncoding;
  final String responseType;
  final List<EffectiveHTTPPolicyIssue> issues;
  bool get isDescribed => issues.isEmpty;
}

/// Adapter identities never cross into the snapshot. Publication happens only
/// after every assignment in the actual installation succeeds.
final class EffectiveHTTPPolicyTracker {
  int _generation = 0;
  EffectiveHTTPPoolConfiguration? _configuration;
  HttpClientAdapter? _adapter;
  IOHttpClientAdapter? _http11;
  Object? _http11Factory;
  ConnectionManager? _manager;
  bool _installationFailed = false;

  void installed({
    required Dio client,
    required IOHttpClientAdapter http11,
    required ConnectionManager? manager,
    required EffectiveHTTPPoolConfiguration configuration,
  }) {
    _adapter = client.httpClientAdapter;
    _http11 = http11;
    _http11Factory = http11.createHttpClient;
    _manager = manager;
    _configuration = configuration;
    _installationFailed = false;
    _generation++;
  }

  void installationFailed() {
    _configuration = null;
    _adapter = null;
    _http11 = null;
    _http11Factory = null;
    _manager = null;
    _installationFailed = true;
  }

  EffectiveHTTPPolicySnapshot capture({
    required Dio client,
    required Dio? http11Client,
    required Object expectedDecoder,
    bool http11Only = false,
  }) {
    final issues = <EffectiveHTTPPolicyIssue>[];
    final adapter = client.httpClientAdapter;
    final configuration = _configuration;
    if (configuration == null) {
      issues.add(_installationFailed
          ? EffectiveHTTPPolicyIssue.poolInstallationFailed
          : EffectiveHTTPPolicyIssue.poolNotInstalled);
    } else {
      if (!identical(adapter, _adapter)) {
        issues.add(EffectiveHTTPPolicyIssue.adapterChanged);
      }
      // A legacy callback override also makes this factory description stale.
      // ignore: deprecated_member_use
      final legacyFactory = _http11?.onHttpClientCreate;
      if (!identical(_http11?.createHttpClient, _http11Factory) ||
          legacyFactory != null ||
          _http11?.validateCertificate != null) {
        issues.add(EffectiveHTTPPolicyIssue.http11FactoryChanged);
      }
      if (configuration.http2Enabled) {
        if (adapter is! Http2Adapter ||
            !identical(adapter.connectionManager, _manager)) {
          issues.add(EffectiveHTTPPolicyIssue.connectionManagerChanged);
        }
        if (adapter is! Http2Adapter ||
            !identical(adapter.fallbackAdapter, _http11) ||
            adapter.onNotSupported != null) {
          issues.add(EffectiveHTTPPolicyIssue.fallbackAdapterChanged);
        }
      }
      if (http11Client != null &&
          !identical(http11Client.httpClientAdapter, _http11)) {
        issues.add(EffectiveHTTPPolicyIssue.fallbackClientChanged);
      }
    }
    if (http11Only && http11Client == null) {
      issues.add(EffectiveHTTPPolicyIssue.fallbackClientChanged);
    }
    final poolDescribed = issues.isEmpty;
    final selectedClient = http11Only ? (http11Client ?? client) : client;

    EffectiveHTTPRetryPolicy? retry;
    final retries = selectedClient.interceptors
        .whereType<RetryInterceptor>().toList();
    if (retries.isEmpty) {
      retry = const EffectiveHTTPRetryPolicy(0, null);
    } else if (retries.length == 1 &&
        retries.single.runtimeType == RetryInterceptor &&
        retries.single.isBoundTo(selectedClient)) {
      retry = EffectiveHTTPRetryPolicy(
        retries.single.count,
        retries.single.delayMilliseconds,
      );
    } else {
      issues.add(EffectiveHTTPPolicyIssue.retryNotDescribed);
    }
    final options = selectedClient.options;
    if (!identical(options.responseDecoder, expectedDecoder)) {
      issues.add(EffectiveHTTPPolicyIssue.decoderChanged);
    }
    String? acceptEncoding;
    final encodings = options.headers.entries.where(
      (entry) => entry.key.toLowerCase() == 'accept-encoding',
    ).toList();
    if (encodings.length == 1 && encodings.single.value is String) {
      acceptEncoding = encodings.single.value as String;
    } else if (encodings.isNotEmpty) {
      issues.add(EffectiveHTTPPolicyIssue.acceptEncodingNotDescribed);
    }
    return EffectiveHTTPPolicySnapshot(
      poolGeneration: _generation,
      http11Only: http11Only,
      pool: poolDescribed ? configuration : null,
      retry: retry,
      connectTimeout: options.connectTimeout,
      receiveIdleTimeout: options.receiveTimeout,
      sendTimeout: options.sendTimeout,
      persistentConnection: options.persistentConnection,
      followRedirects: options.followRedirects,
      maxRedirects: options.maxRedirects,
      acceptEncoding: acceptEncoding,
      responseType: options.responseType.name,
      issues: issues,
    );
  }
}
