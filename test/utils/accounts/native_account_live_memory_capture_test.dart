import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/native_account_live_memory_capture.dart';
import 'package:PiliPlus/services/native_accounts/native_ordered_cookie_jar_export.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_request_state.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

LoginAccount _account(String key, {Set<AccountType>? types}) => LoginAccount(
  BiliCookieJar.fromJson({'DedeUserID': key, 'bili_jct': 'synthetic-csrf',
    'SESSDATA': 'synthetic-session-$key'}),
  'synthetic-access-$key', 'synthetic-refresh-$key', types,
)..activated = true;

List<String> _keys(Map value, String field) => [
  for (final entry in value[field] as List)
    String.fromCharCodes(((entry as Map)['keyUnits'] as List).cast<int>()),
];

void main() {
  late AccountTestStorage storage;
  setUpAll(() async { storage = await AccountTestStorage.open(); });
  setUp(() => storage.reset());
  tearDownAll(() => storage.close());

  test('typed registry query is pure and rejects ambiguous existing matches', () {
    final state = AccountRequestState<Object>();
    expect(state.captureSingleOfType<StringBuffer>(), isNull);
    expect(state.revision, 0);
    final first = StringBuffer('synthetic-first');
    final firstStamp = state.activate(first);
    var revision = state.revision;
    expect(state.captureSingleOfType<StringBuffer>(), same(firstStamp));
    expect(state.revision, revision);
    final second = StringBuffer('synthetic-second');
    state.activate(second);
    revision = state.revision;
    expect(state.captureSingleOfType<StringBuffer>(), isNull);
    expect(state.revision, revision);
    state.revoke(second);
    revision = state.revision;
    expect(state.captureSingleOfType<StringBuffer>(), same(firstStamp));
    expect(state.revision, revision);
  });

  test('real Hive key order differs from owners and numeric MID sorting', () async {
    await Accounts.installCredentials(_account('2'));
    await Accounts.installCredentials(_account('10'));
    var capture = Accounts.captureLiveMemoryShadow();
    expect(_keys(capture.value, 'storedOrder'), ['10', '2']);
    expect(_keys(capture.value, 'ownerOrder'), ['2', '10']);
    final replaced = capture;
    await Accounts.installCredentials(_account('2'));
    capture = Accounts.captureLiveMemoryShadow();
    expect(_keys(capture.value, 'storedOrder'), ['10', '2']);
    expect(_keys(capture.value, 'ownerOrder'), ['10', '2']);
    expect(replaced.verifyCurrent, throwsA(isA<AccountLiveMemoryShadowException>()));
  });

  test('raw 02 and 2 retain distinct exact owners despite equal MID', () async {
    final first = _account('02');
    final second = _account('2');
    expect(first, second); // The legacy operator intentionally equates these.
    await Accounts.installCredentials(first);
    await Accounts.installCredentials(second);
    final value = Accounts.captureLiveMemoryShadow().value;
    expect(_keys(value, 'storedOrder'), ['02', '2']);
    expect((value['records'] as List).length, 3);
    final ordered = value['storedOrder'] as List;
    expect((ordered[0] as Map)['record'], isNot((ordered[1] as Map)['record']));
  });

  test('zero and negative raw MID owners keep source isLogin policy', () async {
    await Accounts.installCredentials(_account('0'));
    await Accounts.installCredentials(_account('-2'));
    final records = Accounts.captureLiveMemoryShadow().value['records'] as List;
    expect((records[0] as Map)['isLogin'], false);
    expect((records[1] as Map)['mid'], -2);
    expect((records[2] as Map)['mid'], 0);
    expect((records[1] as Map)['isLogin'], true);
    expect((records[2] as Map)['isLogin'], true);
  });

  test('four exact slots and temporary anonymous history preserve persisted purposes', () async {
    final accounts = [for (final purpose in AccountType.values)
      _account('${92000 + purpose.index}', types: {purpose})];
    for (final account in accounts) { await Accounts.installCredentials(account); }
    await Accounts.refresh();
    var capture = Accounts.captureLiveMemoryShadow();
    var value = capture.value;
    expect((value['selections'] as List).toSet().length, 4);
    expect(value['history'], (value['selections'] as List)[AccountType.heartbeat.index]);
    Accounts.selectTemporarily(AccountType.heartbeat, AnonymousAccount());
    expect(capture.verifyCurrent, throwsA(isA<AccountLiveMemoryShadowException>()));
    capture = Accounts.captureLiveMemoryShadow();
    value = capture.value;
    expect((value['selections'] as List)[AccountType.heartbeat.index], 0);
    expect(value['history'], (value['selections'] as List)[AccountType.main.index]);
    expect(accounts[AccountType.heartbeat.index].type, {AccountType.heartbeat});
    expect(value['nativeWritesAllowed'], false);
    expect(value['authoritySwitchAllowed'], false);
    expect(value['durabilityVerified'], false);
  });

  test('actual pending install and anonymous reset reject capture without activation', () async {
    final candidate = _account('92010');
    final installing = Accounts.installCredentials(candidate);
    expect(Accounts.account.get(candidate.storageKey), same(candidate));
    expect(Accounts.captureLiveMemoryShadow,
      throwsA(isA<AccountLiveMemoryShadowException>().having((e) => e.code, 'code', 'busy')));
    await installing;
    Accounts.captureLiveMemoryShadow().verifyCurrent();
    final before = Accounts.captureLiveMemoryShadow();
    final resetting = AnonymousAccount().delete();
    expect(Accounts.captureLiveMemoryShadow,
      throwsA(isA<AccountLiveMemoryShadowException>().having((e) => e.code, 'code', 'busy')));
    await resetting;
    expect(before.verifyCurrent, throwsA(isA<AccountLiveMemoryShadowException>()));
    Accounts.captureLiveMemoryShadow().verifyCurrent();
  });

  test('unnotified raw Cookie mutation rejects full checkpoint recapture', () async {
    final account = _account('92011');
    await Accounts.installCredentials(account);
    final revision = Accounts.requestRevision;
    final checkpoint = Completer<void>();
    final future = NativeAccountLiveMemoryCaptureService(
      checkpoint: () => checkpoint.future).capture();
    final rejected = expectLater(future, throwsA(isA<AccountLiveMemoryShadowException>()));
    account.cookieJar.domainCookies['bilibili.com']!['/']!['SESSDATA']!.cookie
      ..value = 'synthetic-changed'
      ..secure = true;
    expect(Accounts.requestRevision, revision);
    checkpoint.complete();
    await rejected;
  });

  test('empty bucket and type changes without revision reject retained snapshot', () async {
    final account = _account('92012');
    await Accounts.installCredentials(account);
    var capture = Accounts.captureLiveMemoryShadow();
    final revision = Accounts.requestRevision;
    account.cookieJar.hostCookies[''] = {'': {}};
    expect(Accounts.requestRevision, revision);
    expect(capture.verifyCurrent, throwsA(isA<AccountLiveMemoryShadowException>()));
    capture = Accounts.captureLiveMemoryShadow();
    account.type.add(AccountType.video);
    expect(capture.verifyCurrent, throwsA(isA<AccountLiveMemoryShadowException>()));
    capture = Accounts.captureLiveMemoryShadow();
    account.activated = false;
    expect(capture.verifyCurrent, throwsA(isA<AccountLiveMemoryShadowException>()));
  });

  test('unknown actual Hive entry fails rather than filtering or reconciling', () async {
    final account = _account('92013');
    await Accounts.account.put('wrong-key', account);
    final revision = Accounts.requestRevision;
    expect(Accounts.captureLiveMemoryShadow,
      throwsA(isA<AccountLiveMemoryShadowException>().having((e) => e.code, 'code', 'invalidStoredOwner')));
    expect(Accounts.requestRevision, revision);
    expect(Accounts.account.get('wrong-key'), same(account));
  });

  test('two individually valid jars exceed one cumulative bucket budget', () async {
    for (final key in ['92014', '92015']) {
      final account = _account(key);
      for (var i = 0; i < 4500; i++) {
        account.cookieJar.hostCookies['synthetic-$i'] = {};
      }
      NativeOrderedCookieJarExporter.export(account.cookieJar);
      await Accounts.installCredentials(account);
    }
    expect(Accounts.captureLiveMemoryShadow,
      throwsA(isA<NativeOrderedCookieJarExportException>().having((e) => e.code, 'code', 'bucketCapacityExceeded')));
  });

  test('credential capacity fails before copying oversized secret fields', () async {
    final account = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '92017', 'bili_jct': 'synthetic-csrf'}),
      List.filled(65537, 's').join(), 'synthetic-refresh',
    )..activated = true;
    await Accounts.installCredentials(account);
    expect(Accounts.captureLiveMemoryShadow,
      throwsA(isA<NativeOrderedCookieJarExportException>().having((e) => e.code, 'code', 'stringCapacityExceeded')));
  });

  test('two individually valid real jars exceed cumulative UTF16 units', () async {
    final value = List.filled(65536, 's').join();
    for (final key in ['92018', '92019']) {
      final account = _account(key);
      final cookies = account.cookieJar.domainCookies['bilibili.com']!['/']!;
      for (var i = 0; i < 18; i++) {
        final name = 'large-$i';
        cookies[name] = SerializableCookie(Cookie(name, value)..setBiliDomain());
      }
      NativeOrderedCookieJarExporter.export(account.cookieJar);
      await Accounts.installCredentials(account);
    }
    expect(Accounts.captureLiveMemoryShadow,
      throwsA(isA<NativeOrderedCookieJarExportException>().having(
        (e) => e.code, 'code', 'unitCapacityExceeded')));
  });

  test('two individually valid real jars exceed cumulative entry count', () async {
    for (final key in ['92020', '92021']) {
      final account = _account(key);
      final cookies = account.cookieJar.hostCookies['synthetic.example'] = {'': {}};
      for (var i = 0; i < 8192; i++) {
        final name = 'entry-$i';
        cookies['']![name] = SerializableCookie(Cookie(name, 's'));
      }
      NativeOrderedCookieJarExporter.export(account.cookieJar);
      await Accounts.installCredentials(account);
    }
    expect(Accounts.captureLiveMemoryShadow,
      throwsA(isA<NativeOrderedCookieJarExportException>().having(
        (e) => e.code, 'code', 'cookieCapacityExceeded')));
  });

  test('whole capture includes anonymous in its actual account capacity', () async {
    await Accounts.importCredentials({
      for (var i = 0; i < 255; i++) '${93000 + i}': _account('${93000 + i}'),
    });
    final accepted = Accounts.captureLiveMemoryShadow();
    expect((accepted.value['records'] as List).length, 256);
    accepted.verifyCurrent();
    await Accounts.installCredentials(_account('93999'));
    expect(Accounts.captureLiveMemoryShadow,
      throwsA(isA<AccountLiveMemoryShadowException>().having(
        (e) => e.code, 'code', 'capacityExceeded')));
  });

  test('capture is deeply owned and does not change revision or credential stamps', () async {
    final account = _account('92016');
    await Accounts.installCredentials(account);
    final stamp = Accounts.captureRequest(account)!;
    final revision = Accounts.requestRevision;
    final capture = Accounts.captureLiveMemoryShadow();
    capture.verifyCurrent();
    expect(Accounts.requestRevision, revision);
    expect(Accounts.captureRequest(account), same(stamp));
    expect(() => capture.value['records'] = [], throwsUnsupportedError);
    final records = capture.value['records'] as List;
    expect(() => records.add(null), throwsUnsupportedError);
    final entry = records[1] as Map;
    final units = entry['accessKeyUnits'] as List;
    expect(() => units[0] = 0, throwsUnsupportedError);
    final jar = entry['jar'] as Map;
    expect(() => jar['hostBuckets'] = [], throwsUnsupportedError);
    final copy = Map.of(jar);
    account.cookieJar.hostCookies['after-capture'] = {};
    expect(jar, copy);
    expect(jar['hostBuckets'], isEmpty);
  });
}
