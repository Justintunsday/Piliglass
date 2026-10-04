import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/wbi_sign.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

class _ControlledNavAdapter implements HttpClientAdapter {
  final pending = <Completer<ResponseBody>>[];
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? body,
      Future<void>? cancel) {
    requests.add(options);
    final completer = Completer<ResponseBody>();
    pending.add(completer);
    return completer.future;
  }
  void finish(int index, Object response) => pending[index].complete(
    ResponseBody.fromString(jsonEncode(response), 200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]}),
  );
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory directory;
  final adapter = _ControlledNavAdapter();
  const source = '0123456789abcdef0123456789abcdef';
  final validNav = {'data': {'wbi_img': {
    'img_url': 'https://fixture.invalid/$source.png',
    'sub_url': 'https://fixture.invalid/$source.png',
  }}};

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    directory = await Directory.systemTemp.createTemp('piliglass-wbi-cache-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox<dynamic>('setting');
    GStorage.localCache = await Hive.openBox<dynamic>('localCache');
    await GStorage.setting.putAll({SettingBoxKey.enableHttp2: false, SettingBoxKey.retryCount: 0});
    Request();
    Request.dio.httpClientAdapter.close(force: true);
    Request.dio.httpClientAdapter = adapter;
    Request.dio.interceptors.clear();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await Hive.close();
    await directory.delete(recursive: true);
  });

  // One isolated process is intentional: legacy _future is static and never
  // explicitly released. Resetting it would conceal the actual old behavior.
  test('actual Hive and Dio replay legacy WBI cache behavior without cutover', () async {
    final evidence = <Map<String, Object?>>[];
    final january = DateTime(2026, 1, 5, 12);
    await GStorage.localCache.putAll({
      LocalCacheKey.timeStamp: DateTime(2025, 12, 5, 12).millisecondsSinceEpoch,
      LocalCacheKey.mixinKey: 'legacy-short-key',
    });
    expect(await WbiSign.getWbiKeys(at: january), 'legacy-short-key');
    expect(adapter.requests, isEmpty);
    evidence.add({'case': 'same-day-number-other-month-year', 'fetches': 0, 'returnsUnvalidatedKey': true});

    await GStorage.localCache.delete(LocalCacheKey.mixinKey);
    final first = WbiSign.getWbiKeys(at: january);
    final shared = WbiSign.getWbiKeys(at: january);
    expect(identical(first, shared), isTrue);
    await _until(() => adapter.requests.length == 1);
    adapter.finish(0, validNav);
    final successful = await first;
    expect(await shared, successful);
    expect(successful, WbiSign.getMixinKey(source + source));
    evidence.add({'case': 'same-day-missing-key', 'sharesFuture': true, 'key': successful});

    await GStorage.localCache.put(LocalCacheKey.timeStamp, DateTime(2026, 1, 4).millisecondsSinceEpoch);
    final refreshing = WbiSign.getWbiKeys(at: january);
    await _until(() => adapter.requests.length == 2);
    expect(GStorage.localCache.get(LocalCacheKey.timeStamp), january.millisecondsSinceEpoch);
    expect(await WbiSign.getWbiKeys(at: january), successful);
    adapter.finish(1, {'data': {'wbi_img': {'img_url': 'invalid', 'sub_url': 'invalid'}}});
    expect(await refreshing, '');
    expect(GStorage.localCache.get(LocalCacheKey.mixinKey), successful);
    evidence.add({'case': 'timestamp-before-fetch-and-parse-failure', 'timestampAlreadyWritten': true,
      'oldKeyReturnedWhileFetching': true, 'emptyResult': true, 'oldPersistedKeyKept': true});

    await GStorage.localCache.delete(LocalCacheKey.mixinKey);
    expect(await WbiSign.getWbiKeys(at: january), '');
    expect(adapter.requests, hasLength(2));
    evidence.add({'case': 'same-day-missing-key-after-failure', 'reusesCompletedEmptyFuture': true});

    final february = DateTime(2026, 2, 6, 12);
    final recover = WbiSign.getWbiKeys(at: february);
    await _until(() => adapter.requests.length == 3);
    adapter.finish(2, validNav);
    expect(await recover, successful);
    expect(adapter.requests.every((request) => request.path == '/x/web-interface/nav'), isTrue);
    evidence.add({'case': 'different-day-number-retries', 'fetches': 3, 'recovered': true});

    final file = File('build/native-signing-check/dart-legacy-cache.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'source': 'actual WbiSign.getWbiKeys, real Hive, controlled Dio nav adapter',
      'runtimeBehaviorChanged': false, 'records': evidence,
    }));
  });
}

Future<void> _until(bool Function() predicate) async {
  for (var index = 0; index < 200; index++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('Timed out waiting for actual Dio adapter');
}
