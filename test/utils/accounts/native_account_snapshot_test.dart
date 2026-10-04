import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/native_account_snapshot_bridge.dart';
import 'package:PiliPlus/services/native_accounts/native_account_snapshot_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

LoginAccount _account(int mid, {String suffix = 'a', Set<AccountType>? types}) => LoginAccount(
  BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'synthetic-csrf-$suffix', 'SESSDATA': 'synthetic-session-$suffix'}),
  'synthetic-access-$suffix', 'synthetic-refresh-$suffix', types,
)..activated = true;

List<Map> _accounts(Map snapshot) => (snapshot['accounts'] as List).cast<Map>();
Map _identity(Map snapshot, int mid) => _accounts(snapshot).firstWhere((a) => a['mid'] == mid)['identity'] as Map;
Map _selection(Map snapshot, AccountType purpose) => (snapshot['selections'] as List).cast<Map>().firstWhere((s) => s['purpose'] == purpose.name);

void main() {
  late AccountTestStorage storage;
  late NativeAccountSnapshotService service;
  setUpAll(() async { storage = await AccountTestStorage.open(); });
  setUp(() async { await storage.reset(); service = NativeAccountSnapshotService(); });
  tearDownAll(() => storage.close());

  test('four real Hive purposes and history use their distinct owners', () async {
    for (final purpose in AccountType.values) {
      await Accounts.installCredentials(_account(100 + purpose.index, types: {purpose}));
    }
    await Accounts.refresh();
    final snapshot = await service.selectionSnapshot();
    for (final purpose in AccountType.values) {
      expect(_selection(snapshot, purpose)['identity'], _identity(snapshot, 100 + purpose.index));
      expect(_selection(snapshot, purpose)['temporary'], false);
    }
    expect(snapshot['history'], _identity(snapshot, 101));
    expect(snapshot['nativeWritesAllowed'], false);
    expect(jsonEncode(snapshot), isNot(contains('synthetic-')));
  });

  test('temporary anonymous heartbeat preserves Hive assignment and history falls back to main', () async {
    final a = _account(201, types: {AccountType.main, AccountType.heartbeat});
    await Accounts.installCredentials(a);
    await Accounts.refresh();
    Accounts.selectTemporarily(AccountType.heartbeat, AnonymousAccount());
    final snapshot = await service.selectionSnapshot();
    expect(_selection(snapshot, AccountType.heartbeat)['temporary'], true);
    expect(snapshot['history'], _identity(snapshot, 201));
    expect(a.type, {AccountType.main, AccountType.heartbeat});
    expect(Accounts.account.get('201'), same(a));
  });

  test('A B A switches keep ownership, same MID installation changes it', () async {
    final a = _account(301);
    final b = _account(302);
    await Accounts.installCredentials(a);
    await Accounts.installCredentials(b);
    Accounts.selectTemporarily(AccountType.recommend, a);
    final first = await service.selectionSnapshot();
    final owner = service.currentOwnerWire(a)!;
    Accounts.selectTemporarily(AccountType.recommend, b);
    await service.selectionSnapshot();
    Accounts.selectTemporarily(AccountType.recommend, a);
    final returned = await service.selectionSnapshot();
    expect(_identity(first, 301), _identity(returned, 301));
    final replacement = _account(301, suffix: 'replacement');
    await Accounts.installCredentials(replacement);
    final updated = await service.selectionSnapshot();
    expect(_identity(updated, 301), isNot(_identity(first, 301)));
    expect(service.resolveOwner(authorityEpoch: owner['authorityEpoch']! as String,
      ownerToken: owner['ownerToken']! as String, generation: owner['generation']! as int), isNull);
    expect(service.currentOwnerWire(a), isNull);
  });

  test('selection and cookie mutation while capture awaits reject copied data', () async {
    final checkpoint = Completer<void>();
    final blocked = NativeAccountSnapshotService(checkpoint: () => checkpoint.future);
    final future = blocked.selectionSnapshot();
    final rejected = expectLater(future, throwsA(isA<NativeAccountSnapshotException>()));
    Accounts.notifyCookieMutation(AnonymousAccount());
    checkpoint.complete();
    await rejected;
  });

  test('mutable activation without revision and credentials replacement reject capture', () async {
    final a = _account(401);
    await Accounts.installCredentials(a);
    final checkpoint = Completer<void>();
    final blocked = NativeAccountSnapshotService(checkpoint: () => checkpoint.future);
    final result = blocked.selectionSnapshot();
    final rejected = expectLater(result, throwsA(isA<NativeAccountSnapshotException>()));
    a.activated = false;
    checkpoint.complete();
    await rejected;
  });

  test('anonymous same-object reset creates a new token and generation', () async {
    final before = await service.selectionSnapshot();
    await AnonymousAccount().delete();
    final after = await service.selectionSnapshot();
    expect(_identity(before, 0), isNot(_identity(after, 0)));
    expect(after['authorityEpoch'], before['authorityEpoch']);
  });

  test('full cookie staging preserves actual jar attributes and exports synthetic golden', () async {
    final a = _account(501, types: {AccountType.recommend});
    await Accounts.installCredentials(a);
    await a.cookieJar.saveFromResponse(Uri.parse('https://api.bilibili.com/x/test'), [
      Cookie('duplicate', 'root')..domain = '.bilibili.com'..path = '/',
      Cookie('duplicate', 'nested')..domain = '.bilibili.com'..path = '/x'
        ..secure = true..httpOnly = true..sameSite = SameSite.lax..maxAge = 500,
      Cookie('host', 'host-value')..path = '/x'..expires = DateTime.utc(2035, 4, 9),
    ]);
    Accounts.notifyCookieMutation(a);
    await a.onChange();
    await Accounts.refresh();
    final bridge = NativeAccountSnapshotBridge(service);
    final export = await bridge.handle('exportNativeAccountStaging', null);
    final entries = (export['entries'] as List).cast<Map>();
    final token = _identity(export['snapshot'] as Map, 501)['ownerToken'];
    final entry = entries.firstWhere((e) => (e['identity'] as Map)['ownerToken'] == token);
    expect(entry['legacyHiveAttributesIncomplete'], true);
    final cookies = (entry['cookies'] as List).cast<Map>();
    expect(cookies.where((c) => c['name'] == 'duplicate').length, 2);
    final nested = cookies.firstWhere((c) => c['name'] == 'duplicate' && c['path'] == '/x');
    expect(nested['secure'], true);
    expect(nested['httpOnly'], true);
    expect(nested['sameSite'], 'lax');
    expect(nested['maxAgeSeconds'], 500);
    final host = cookies.firstWhere((c) => c['name'] == 'host');
    expect(host['hostOnly'], true);
    expect(host['cookieDomain'], null);
    expect(host['expiresMicroseconds'], DateTime.utc(2035, 4, 9).microsecondsSinceEpoch);
    final directory = Directory('build/native-account-contracts');
    await directory.create(recursive: true);
    await File('${directory.path}/live.json').writeAsString(jsonEncode(export));
  });

  test('bridge rejects extra arguments and unrelated commands', () async {
    final bridge = NativeAccountSnapshotBridge(service);
    expect((await bridge.handle('loadNativeAccountSelection', {'unknown': 1}))['code'], 'invalidArguments');
    expect((await bridge.handle('deleteAccount', null))['code'], 'unknownCommand');
  });

  for (final mutation in ['replace', 'delete', 'clear', 'import']) {
    test('$mutation while capture awaits cannot publish an obsolete owner', () async {
      final a = _account(701, types: {AccountType.recommend});
      await Accounts.installCredentials(a);
      await Accounts.refresh();
      final checkpoint = Completer<void>();
      final blocked = NativeAccountSnapshotService(checkpoint: () => checkpoint.future);
      final future = blocked.selectionSnapshot();
      final rejected = expectLater(future, throwsA(isA<NativeAccountSnapshotException>()));
      switch (mutation) {
        case 'replace': await Accounts.installCredentials(_account(701, suffix: 'replace'));
        case 'delete': await Accounts.deleteAll({a});
        case 'clear': await Accounts.clear();
        case 'import': await Accounts.importCredentials({'701': _account(701, suffix: 'import')});
      }
      checkpoint.complete();
      await rejected;
    });
  }

  test('shared account serves all purposes and epoch from another service is rejected', () async {
    final a = _account(801, types: AccountType.values.toSet());
    await Accounts.installCredentials(a);
    await Accounts.refresh();
    final snapshot = await service.selectionSnapshot();
    for (final purpose in AccountType.values) {
      expect(_selection(snapshot, purpose)['identity'], _identity(snapshot, 801));
    }
    final owner = service.currentOwnerWire(a)!;
    expect(NativeAccountSnapshotService().resolveOwner(authorityEpoch: owner['authorityEpoch']! as String,
      ownerToken: owner['ownerToken']! as String, generation: owner['generation']! as int), isNull);
  });
}
