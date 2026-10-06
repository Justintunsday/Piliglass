import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

DefaultCookieJar _jar(int mid, String session) => BiliCookieJar.fromJson({
  'DedeUserID': '$mid',
  'bili_jct': 'synthetic-delete-csrf',
  'SESSDATA': session,
});

LoginAccount _account(int mid, String session) => LoginAccount(
  _jar(mid, session),
  'synthetic-delete-access',
  'synthetic-delete-refresh',
)..activated = true;

void main() {
  late AccountTestStorage storage;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });
  setUp(() => storage.reset());
  tearDownAll(() => storage.close());

  test('revoked owner clears real jar and Hive memory before deletion awaits', () async {
    final owner = _account(820001, 'synthetic-original');
    await Accounts.installCredentials(owner);
    final stamp = Accounts.captureRequest(owner)!;

    final deleting = owner.delete();
    expect(Accounts.isCurrentRequest(stamp), isFalse);
    expect(owner.onChange(), isNull);
    expect(owner.cookieJar.domainCookies, isEmpty);
    expect(owner.cookieJar.hostCookies, isEmpty);
    expect(Accounts.account.containsKey(owner.storageKey), isFalse);
    await deleting;
    await owner.delete();
    expect(Accounts.captureRequest(owner), isNull);
    expect(Accounts.account.containsKey(owner.storageKey), isFalse);
  });

  test('in-flight old deletion never removes newly installed same-MID owner', () async {
    final old = _account(820002, 'synthetic-old');
    await Accounts.installCredentials(old);
    final oldStamp = Accounts.captureRequest(old)!;
    final deleting = old.delete();
    final successor = _account(820002, 'synthetic-successor');
    final installing = Accounts.installCredentials(successor);
    expect(Accounts.account.get(successor.storageKey), same(successor));
    expect(Accounts.captureRequest(successor), isNull);
    await Future.wait([deleting, installing]);

    final successorStamp = Accounts.captureRequest(successor)!;
    await old.delete();
    await Accounts.refresh();
    expect(Accounts.account.get(successor.storageKey), same(successor));
    expect(successor.cookieJar.toJson()['SESSDATA'], 'synthetic-successor');
    expect(Accounts.isCurrentRequest(successorStamp), isTrue);
    expect(Accounts.isCurrentRequest(oldStamp), isFalse);
    expect(old.onChange(), isNull);
  });

  test('jar completion error preserves concurrent Hive deletion and revocation', () async {
    final failure = StateError('synthetic jar deletion completion failure');
    final jar = _FailingCompletionJar(failure)
      ..domainCookies.addAll(_jar(820003, 'synthetic-partial').domainCookies);
    final owner = LoginAccount(jar, 'synthetic-access', 'synthetic-refresh')
      ..activated = true;
    await Accounts.installCredentials(owner);
    final stamp = Accounts.captureRequest(owner)!;

    final deleting = owner.delete();
    expect(jar.domainCookies, isEmpty);
    expect(Accounts.account.containsKey(owner.storageKey), isFalse);
    expect(Accounts.isCurrentRequest(stamp), isFalse);
    await expectLater(deleting, throwsA(same(failure)));
    await Accounts.refresh();
    expect(Accounts.captureRequest(owner), isNull);
    expect(owner.onChange(), isNull);
    expect(Accounts.account.containsKey(owner.storageKey), isFalse);
  });
}

/// The actual CookieJar clears its maps; only the completion reports a synthetic
/// error. This is partial-operation evidence, not a durable Hive receipt.
class _FailingCompletionJar extends DefaultCookieJar {
  final StateError failure;

  _FailingCompletionJar(this.failure);

  @override
  Future<void> deleteAll() => super.deleteAll().then<void>((_) => throw failure);
}
