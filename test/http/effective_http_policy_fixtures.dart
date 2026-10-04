import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/effective_http_policy.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// Separate entrypoints provide real cold boots, not a reset of lazy statics.
void runEffectiveHTTPPolicyFixtures({required bool http2, required int retry}) {
  late Directory directory;

  Future<void> preferences({bool proxy = false, String port = '8080'}) =>
      GStorage.setting.putAll({
        SettingBoxKey.enableHttp2: http2,
        SettingBoxKey.retryCount: retry,
        SettingBoxKey.retryDelay: 500,
        SettingBoxKey.enableSystemProxy: proxy,
        SettingBoxKey.systemProxyHost: '127.0.0.1',
        SettingBoxKey.systemProxyPort: port,
        SettingBoxKey.badCertificateCallback: false,
      });

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Only this isolated test process permits actual IPv4 loopback traffic.
    HttpOverrides.global = null;
    directory = await Directory.systemTemp.createTemp('piliglass-policy-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox<dynamic>('setting');
    await preferences();
    Request();
  });
  setUp(() async {
    await preferences();
    Request.resetAdaptersForNetworkChange();
  });
  tearDownAll(() async {
    if (http2) Request.http11Dio.close(force: true);
    Request.dio.close(force: true);
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('effective boot values survive changed Pref before pool replacement', () async {
    final before = Request.effectiveHTTPPolicy;
    expect(before.isDescribed, isTrue);
    expect(before.pool!.http2Enabled, http2);
    expect(before.pool!.http2ALPN, http2 ? ['h2'] : isEmpty);
    expect(before.pool!.proxyEnabled, isFalse);
    expect(before.retry!.count, retry);
    expect(before.retry!.delayMilliseconds, retry == 0 ? null : 500);
    expect(before.connectTimeout, const Duration(seconds: 10));
    expect(before.receiveIdleTimeout, const Duration(seconds: 10));
    expect(before.sendTimeout, isNull);
    expect(before.acceptEncoding, 'br,gzip');
    expect(before.persistentConnection, isTrue);
    expect(before.followRedirects, isTrue);
    expect(before.maxRedirects, 5);
    expect(before.pool!.idleTimeout, const Duration(seconds: 15));
    expect(before.pool!.autoUncompress, isFalse);
    expect(before.responseType, 'json');
    await GStorage.setting.putAll({
      SettingBoxKey.enableHttp2: !http2,
      SettingBoxKey.retryCount: retry == 0 ? 9 : 0,
      SettingBoxKey.retryDelay: 1,
      SettingBoxKey.enableSystemProxy: true,
      SettingBoxKey.badCertificateCallback: true,
    });
    final after = Request.effectiveHTTPPolicy;
    expect(after.poolGeneration, before.poolGeneration);
    expect(identical(after.pool, before.pool), isTrue);
    expect(after.retry!.count, retry);
    expect(after.retry!.delayMilliseconds, before.retry!.delayMilliseconds);
    expect(after.pool!.http11AcceptsBadCertificate, isFalse);
    expect(after.pool!.http2AcceptsBadCertificate, http2 ? false : null);
    expect(() => after.issues.add(EffectiveHTTPPolicyIssue.adapterChanged),
        throwsUnsupportedError);
  });

  test('only completed pool installs publish proxy, trust and generation', () async {
    final before = Request.effectiveHTTPPolicy;
    await preferences(proxy: true);
    Request.resetAdaptersForNetworkChange();
    final proxy = Request.effectiveHTTPPolicy;
    expect(proxy.poolGeneration, before.poolGeneration + 1);
    expect(proxy.isDescribed, isTrue);
    expect(proxy.pool!.proxyHost, '127.0.0.1');
    expect(proxy.pool!.proxyPort, 8080);
    expect(proxy.pool!.http11AcceptsBadCertificate, isTrue);
    expect(proxy.pool!.http2AcceptsBadCertificate, http2 ? true : null);
    expect(before.pool!.proxyEnabled, isFalse); // Old snapshot stays immutable.

    await preferences(proxy: true, port: 'unparseable');
    await GStorage.setting.put(SettingBoxKey.badCertificateCallback, true);
    Request.resetAdaptersForNetworkChange();
    final invalidProxy = Request.effectiveHTTPPolicy;
    expect(invalidProxy.pool!.proxyEnabled, isFalse);
    expect(invalidProxy.pool!.proxyHost, isNull);
    expect(invalidProxy.pool!.http11AcceptsBadCertificate, isFalse);
    expect(invalidProxy.pool!.http2AcceptsBadCertificate, http2 ? true : null);
    expect(invalidProxy.retry!.count, retry);
  });

  test('lazy HTTP11 clone uses actual copied retry and shares replacement pool', () {
    final main = Request.effectiveHTTPPolicy;
    final h11 = Request.http11Dio;
    final snapshot = Request.effectiveHTTP11Policy;
    expect(snapshot.http11Only, isTrue);
    expect(snapshot.isDescribed, isTrue);
    expect(identical(snapshot.pool, main.pool), isTrue);
    expect(snapshot.retry!.count, retry);
    final retries = h11.interceptors.whereType<RetryInterceptor>();
    expect(retries.length, retry == 0 ? 0 : 1);
    if (retry != 0) expect(retries.single.isBoundTo(h11), isTrue);
    final previous = h11.httpClientAdapter;
    Request.resetAdaptersForNetworkChange();
    expect(identical(h11.httpClientAdapter, previous), isFalse);
    expect(Request.effectiveHTTPPolicy.isDescribed, isTrue);
    expect(Request.effectiveHTTP11Policy.isDescribed, isTrue);
    if (http2) {
      expect(identical(h11.httpClientAdapter,
          (Request.dio.httpClientAdapter as Http2Adapter).fallbackAdapter), isTrue);
    } else {
      expect(identical(h11, Request.dio), isTrue);
    }
  });

  test('failure after partial replacement is unknown and does not advance generation', () {
    final before = Request.effectiveHTTPPolicy;
    final throwing = _ThrowingCloseAdapter();
    if (http2) {
      final adapter = Request.dio.httpClientAdapter as Http2Adapter;
      final manager = adapter.connectionManager;
      adapter.fallbackAdapter.close(force: true);
      adapter.fallbackAdapter = throwing;
      Request.resetAdaptersForNetworkChange();
      expect(identical(adapter.connectionManager, manager), isFalse);
    } else {
      Request.dio.httpClientAdapter.close(force: true);
      Request.dio.httpClientAdapter = throwing;
      Request.resetAdaptersForNetworkChange();
    }
    final failed = Request.effectiveHTTPPolicy;
    expect(failed.pool, isNull);
    expect(failed.poolGeneration, before.poolGeneration);
    expect(failed.issues, contains(EffectiveHTTPPolicyIssue.poolInstallationFailed));
    throwing.fail = false;
    Request.resetAdaptersForNetworkChange();
    final recovered = Request.effectiveHTTPPolicy;
    expect(recovered.isDescribed, isTrue);
    expect(recovered.poolGeneration, before.poolGeneration + 1);
  });

  test('untracked adapter, factory, decoder and wrong retry client are rejected', () {
    final original = Request.dio.httpClientAdapter;
    final replacement = IOHttpClientAdapter();
    Request.dio.httpClientAdapter = replacement;
    expect(Request.effectiveHTTPPolicy.pool, isNull);
    expect(Request.effectiveHTTPPolicy.issues,
        contains(EffectiveHTTPPolicyIssue.adapterChanged));
    Request.dio.httpClientAdapter = original;
    replacement.close(force: true);

    final h11 = (http2 ? (original as Http2Adapter).fallbackAdapter : original)
        as IOHttpClientAdapter;
    final factory = h11.createHttpClient;
    h11.createHttpClient = HttpClient.new;
    expect(Request.effectiveHTTPPolicy.pool, isNull);
    h11.createHttpClient = factory;
    final decoder = Request.dio.options.responseDecoder;
    Request.dio.options.responseDecoder = null;
    expect(Request.effectiveHTTPPolicy.issues,
        contains(EffectiveHTTPPolicyIssue.decoderChanged));
    Request.dio.options.responseDecoder = decoder;
    final other = Dio();
    final wrongRetry = RetryInterceptor(other, 3, 17);
    Request.dio.interceptors.add(wrongRetry);
    expect(Request.effectiveHTTPPolicy.retry, isNull);
    Request.dio.interceptors.remove(wrongRetry);
    other.close(force: true);
    expect(Request.effectiveHTTPPolicy.isDescribed, isTrue);
  });

  test('main and forced HTTP11 retain actual shared BaseOptions', () {
    final h11 = Request.http11Dio;
    final before = Request.effectiveHTTP11Policy;
    final mainBefore = Request.effectiveHTTPPolicy;
    expect(identical(h11.options, Request.dio.options), isTrue);
    try {
      h11.options
        ..receiveTimeout = const Duration(seconds: 7)
        ..headers['accept-encoding'] = 'gzip'
        ..followRedirects = false;
      final changed = Request.effectiveHTTP11Policy;
      expect(changed.receiveIdleTimeout, const Duration(seconds: 7));
      expect(changed.acceptEncoding, 'gzip');
      expect(changed.followRedirects, isFalse);
      expect(before.receiveIdleTimeout, const Duration(seconds: 10));
      expect(mainBefore.receiveIdleTimeout, const Duration(seconds: 10));
      expect(Request.effectiveHTTPPolicy.receiveIdleTimeout,
          const Duration(seconds: 7));
      expect(Request.effectiveHTTPPolicy.acceptEncoding, 'gzip');
    } finally {
      h11.options
        ..receiveTimeout = before.receiveIdleTimeout
        ..headers['accept-encoding'] = before.acceptEncoding
        ..followRedirects = before.followRedirects;
    }
  });

  test('real existing Dio HTTP11 wire keeps encoding and manual gzip decoding', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final served = server.first.then((request) async {
      expect(request.headers.value('accept-encoding'), 'br,gzip');
      request.response
        ..headers.contentType = ContentType.json
        ..headers.set('content-encoding', 'gzip')
        ..add(gzip.encode(utf8.encode('{"ok":true,"value":"原生迁移"}')));
      await request.response.close();
    });
    try {
      final h11 = Request.http11Dio;
      final snapshot = Request.effectiveHTTP11Policy;
      expect(snapshot.isDescribed, isTrue);
      final response = await h11.get<Map<String, dynamic>>(
        'http://127.0.0.1:${server.port}/effective-policy',
      );
      await served;
      expect(response.data, {'ok': true, 'value': '原生迁移'});
      expect(Request.effectiveHTTP11Policy.poolGeneration, snapshot.poolGeneration);
    } finally {
      await server.close(force: true);
    }
  });
}

// Only failure injection: normal paths use the production IO/H2 adapters.
class _ThrowingCloseAdapter extends IOHttpClientAdapter {
  bool fail = true;

  @override
  void close({bool force = false}) {
    if (fail) throw StateError('synthetic adapter close failure');
    super.close(force: force);
  }
}
