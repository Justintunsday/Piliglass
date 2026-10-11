import 'package:PiliPlus/services/native_accounts/account_credential_reader.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

LoginAccount _account(int mid) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'csrf-$mid',
    'SESSDATA': 'session-$mid',
  }),
  'access-$mid',
  'refresh-$mid',
)..activated = true;

void main() {
  late AccountTestStorage storage;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });
  setUp(() => storage.reset());
  tearDownAll(() => storage.close());

  test('installedAccounts matches the real box content, order and identity', () async {
    final first = _account(2);
    final second = _account(10);
    await Accounts.installCredentials(first);
    await Accounts.installCredentials(second);
    final direct = Accounts.account.toMap();
    final seam = Accounts.installedAccounts();
    expect(seam.keys.toList(), direct.keys.toList());
    expect(seam.length, direct.length);
    for (final key in direct.keys) {
      expect(identical(seam[key], direct[key]), true);
    }
    expect(seam.values.toList(), containsAll([first, second]));
    // The seam is a fresh snapshot: mutating it never touches the box.
    seam.remove(seam.keys.first);
    expect(Accounts.account.toMap().length, 2);
  });

  test('installedAccounts is empty on an empty box and follows removal', () async {
    expect(Accounts.installedAccounts(), isEmpty);
    final account = _account(20);
    await Accounts.installCredentials(account);
    expect(Accounts.installedAccounts().keys.toList(), ['20']);
    await Accounts.deleteAll({account});
    expect(Accounts.installedAccounts(), isEmpty);
  });

  test('reader summaries keep the page emptiness checks equivalent to the box', () async {
    expect(accountCredentialReader.visibleAccounts(), isEmpty);
    final first = _account(30);
    final second = _account(31);
    await Accounts.installCredentials(first);
    await Accounts.installCredentials(second);
    final summaries = accountCredentialReader.visibleAccounts();
    expect(
      [for (final summary in summaries) summary.storageKey],
      Accounts.installedAccounts().keys.cast<String>().toList(),
    );
    expect([for (final summary in summaries) summary.mid], [30, 31]);
    expect(summaries.every((summary) => summary.isLogin), true);
    expect(Accounts.installedAccounts().isNotEmpty, true);
  });

  test('page read seams never activate, reconcile or bump the revision', () async {
    final account = _account(40);
    await Accounts.installCredentials(account);
    final revision = Accounts.requestRevision;
    final orphan = _account(41);
    expect(Accounts.ownsCredentials(orphan), false);
    Accounts.installedAccounts();
    accountCredentialReader.visibleAccounts();
    expect(Accounts.requestRevision, revision);
    expect(Accounts.ownsCredentials(orphan), false);
    expect(Accounts.ownsCredentials(account), true);
  });
}
