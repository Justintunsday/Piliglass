import 'dart:async';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/account_install_persistence_port.dart';
import 'package:PiliPlus/services/native_accounts/account_reset_persistence_port.dart';
import 'package:PiliPlus/services/native_accounts/account_write_back_coordinator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

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

Matcher get _frozen => isA<StateError>().having(
  (error) => error.message,
  'message',
  'Account write-back is frozen',
);

Future<String?> _cookie(Account account, String name) async {
  final cookies = await account.cookieJar.loadForRequest(
    Uri.parse('https://api.bilibili.com/x'),
  );
  for (final cookie in cookies) {
    if (cookie.name == name) return cookie.value;
  }
  return null;
}

final class _GatedInstallPort implements AccountInstallPersistencePort {
  final gate = Completer<void>();
  final started = Completer<void>();

  @override
  Future<void> writeLegacyInstall(
    Box<LoginAccount> box,
    String key,
    LoginAccount value,
  ) async {
    if (!started.isCompleted) started.complete();
    await gate.future;
    await accountInstallPersistencePort.writeLegacyInstall(box, key, value);
  }

  @override
  Future<void> writeLegacyImport(
    Box<LoginAccount> box,
    Map<String, LoginAccount> values,
  ) => accountInstallPersistencePort.writeLegacyImport(box, values);
}

final class _GatedResetPort implements AccountResetPersistencePort {
  final gate = Completer<void>();
  final started = Completer<void>();

  @override
  Future<void> clearAnonymousCookies(AnonymousAccount owner) =>
      accountResetPersistencePort.clearAnonymousCookies(owner);

  @override
  Future<int> clearLegacyAccounts(Box<LoginAccount> box) async {
    if (!started.isCompleted) started.complete();
    await gate.future;
    return accountResetPersistencePort.clearLegacyAccounts(box);
  }
}

final class _GatedDeleteJar extends DefaultCookieJar {
  _GatedDeleteJar(int mid) : super(ignoreExpires: true) {
    final seed = BiliCookieJar.fromJson({
      'DedeUserID': '$mid',
      'bili_jct': 'csrf-$mid',
      'SESSDATA': 'session-$mid',
    });
    domainCookies.addAll(seed.domainCookies);
    hostCookies.addAll(seed.hostCookies);
  }

  final gate = Completer<void>();
  final started = Completer<void>();

  @override
  Future<void> deleteAll() async {
    final real = super.deleteAll();
    if (!started.isCompleted) started.complete();
    await real;
    await gate.future;
  }
}

final class _PersistenceHold {
  final gate = Completer<void>();
  final started = Completer<void>();
}

final class _GatedPersistenceAccount extends LoginAccount {
  _GatedPersistenceAccount()
      : super(
          BiliCookieJar.fromJson({
            'DedeUserID': '940121',
            'bili_jct': 'csrf-940121',
            'SESSDATA': 'session-940121',
          }),
          'access-940121',
          'refresh-940121',
        ) {
    activated = true;
  }

  final List<_PersistenceHold> _pending = [];
  _PersistenceHold? _active;

  _PersistenceHold holdNextPersistence() {
    final hold = _PersistenceHold();
    _pending.add(hold);
    return hold;
  }

  void releasePersistence(_PersistenceHold hold) {
    if (identical(_active, hold)) {
      _active = null;
      hold.gate.complete();
    }
  }

  @override
  Future<void>? onChange() {
    final real = super.onChange();
    if (_pending.isEmpty) return real;
    final hold = _pending.removeAt(0);
    _active = hold;
    hold.started.complete();
    return _join(real, hold.gate.future);
  }

  static Future<void> _join(Future<void>? real, Future<void> gate) async {
    if (real != null) await real;
    await gate;
  }
}

void main() {
  late AccountTestStorage storage;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
  });
  setUp(() => storage.reset());
  tearDownAll(() => storage.close());

  test('frozen install is rejected before any state change', () async {
    final coordinator = AccountWriteBackCoordinator();
    await coordinator.freeze();
    final account = _account(940001);
    final revision = Accounts.requestRevision;
    await expectLater(
      Accounts.installCredentials(account, coordinator: coordinator),
      throwsA(_frozen),
    );
    expect(Accounts.account.isEmpty, true);
    expect(Accounts.ownsCredentials(account), false);
    expect(Accounts.requestRevision, revision);
    expect(coordinator.admittedCount, 0);
    expect(coordinator.liveOperationCount, 0);
  });

  test('frozen import is rejected before any candidate is written', () async {
    final coordinator = AccountWriteBackCoordinator();
    await coordinator.freeze();
    final revision = Accounts.requestRevision;
    await expectLater(
      Accounts.importCredentials(
        {940011: _account(940011), 940012: _account(940012)},
        coordinator: coordinator,
      ),
      throwsA(_frozen),
    );
    expect(Accounts.account.isEmpty, true);
    expect(Accounts.requestRevision, revision);
    expect(coordinator.admittedCount, 0);
  });

  test('frozen deleteAll keeps credentials, box and jar intact', () async {
    final coordinator = AccountWriteBackCoordinator();
    final account = _account(940021);
    await Accounts.installCredentials(account);
    await coordinator.freeze();
    await expectLater(
      Accounts.deleteAll({account}, coordinator: coordinator),
      throwsA(_frozen),
    );
    expect(Accounts.ownsCredentials(account), true);
    expect(Accounts.account.get('940021'), same(account));
    expect(await _cookie(account, 'SESSDATA'), 'session-940021');
    expect(coordinator.admittedCount, 0);
  });

  test('frozen clear keeps owners, box and anonymous reset state intact', () async {
    final coordinator = AccountWriteBackCoordinator();
    final account = _account(940031);
    await Accounts.installCredentials(account);
    await coordinator.freeze();
    await expectLater(
      Accounts.clear(coordinator: coordinator),
      throwsA(_frozen),
    );
    expect(Accounts.ownsCredentials(account), true);
    expect(Accounts.account.get('940031'), same(account));
    expect(coordinator.admittedCount, 0);
  });

  test('in-flight install holds the admission until the port write lands', () async {
    final coordinator = AccountWriteBackCoordinator();
    final port = _GatedInstallPort();
    final account = _account(940041);
    final installing = Accounts.installCredentials(
      account,
      coordinator: coordinator,
      persistencePort: port,
    );
    await port.started.future;
    expect(coordinator.liveOperationCount, 1);
    var drained = false;
    final drain = coordinator.freeze()
      ..then((_) => drained = true);
    await Future<void>.value();
    expect(drained, false);
    expect(coordinator.tryAdmit(), isNull);
    port.gate.complete();
    await installing;
    await drain;
    expect(drained, true);
    expect(Accounts.account.get('940041'), same(account));
    expect(Accounts.ownsCredentials(account), true);
    expect(coordinator.liveOperationCount, 0);
  });

  test('in-flight deleteAll holds exactly one admission until both ports land', () async {
    final coordinator = AccountWriteBackCoordinator();
    final jar = _GatedDeleteJar(940051);
    final account = LoginAccount(jar, 'access-940051', 'refresh-940051')
      ..activated = true;
    await Accounts.installCredentials(account);
    final deleting = Accounts.deleteAll({account}, coordinator: coordinator);
    await jar.started.future;
    expect(coordinator.liveOperationCount, 1);
    var drained = false;
    final drain = coordinator.freeze()
      ..then((_) => drained = true);
    await Future<void>.value();
    expect(drained, false);
    jar.gate.complete();
    await deleting;
    await drain;
    expect(drained, true);
    expect(Accounts.account.get('940051'), isNull);
    expect(Accounts.ownsCredentials(account), false);
    expect(coordinator.liveOperationCount, 0);
  });

  test('in-flight clear holds one admission and the nested anonymous delete does not re-admit', () async {
    final coordinator = AccountWriteBackCoordinator();
    final port = _GatedResetPort();
    final account = _account(940061);
    await Accounts.installCredentials(account);
    final clearing = Accounts.clear(
      persistencePort: port,
      coordinator: coordinator,
    );
    await port.started.future;
    expect(coordinator.liveOperationCount, 1);
    var drained = false;
    final drain = coordinator.freeze()
      ..then((_) => drained = true);
    await Future<void>.value();
    expect(drained, false);
    port.gate.complete();
    await clearing;
    await drain;
    expect(drained, true);
    expect(Accounts.account.isEmpty, true);
    expect(coordinator.liveOperationCount, 0);
  });

  test('direct account deletes keep the frozen rejection and zero mutation', () async {
    final coordinator = AccountWriteBackCoordinator();
    final account = _account(940071);
    await Accounts.installCredentials(account);
    await coordinator.freeze();
    expect(
      () => account.delete(coordinator: coordinator),
      throwsA(_frozen),
    );
    await expectLater(
      AnonymousAccount().delete(coordinator: coordinator),
      throwsA(_frozen),
    );
    expect(Accounts.ownsCredentials(account), true);
    expect(Accounts.account.get('940071'), same(account));
    expect(coordinator.admittedCount, 0);
  });

  test('an injected unfrozen coordinator keeps the normal lifecycle working', () async {
    final coordinator = AccountWriteBackCoordinator();
    final account = _account(940081);
    await Accounts.installCredentials(account, coordinator: coordinator);
    expect(Accounts.account.get('940081'), same(account));
    expect(coordinator.liveOperationCount, 0);
    await Accounts.deleteAll({account}, coordinator: coordinator);
    expect(Accounts.account.isEmpty, true);
    expect(coordinator.liveOperationCount, 0);
  });

  test('frozen set keeps the selection and purpose unchanged', () async {
    final coordinator = AccountWriteBackCoordinator();
    final account = _account(940091);
    await Accounts.installCredentials(account);
    await coordinator.freeze();
    await expectLater(
      Accounts.set(AccountType.recommend, account, coordinator: coordinator),
      throwsA(_frozen),
    );
    expect(Accounts.get(AccountType.recommend) is AnonymousAccount, true);
    expect(account.type.contains(AccountType.recommend), false);
    expect(coordinator.admittedCount, 0);
  });

  test('frozen selectTemporarily keeps the selection unchanged', () async {
    final coordinator = AccountWriteBackCoordinator();
    final account = _account(940101);
    await Accounts.installCredentials(account);
    await coordinator.freeze();
    expect(
      () => Accounts.selectTemporarily(
        AccountType.video,
        account,
        coordinator: coordinator,
      ),
      throwsA(_frozen),
    );
    expect(Accounts.get(AccountType.video) is AnonymousAccount, true);
    expect(coordinator.admittedCount, 0);
  });

  test('frozen refresh is rejected before reconciling stored owners', () async {
    final coordinator = AccountWriteBackCoordinator();
    final account = _account(940111);
    await Accounts.installCredentials(account);
    await coordinator.freeze();
    final revision = Accounts.requestRevision;
    expect(
      () => Accounts.refresh(coordinator: coordinator),
      throwsA(_frozen),
    );
    expect(Accounts.ownsCredentials(account), true);
    expect(Accounts.requestRevision, revision);
    expect(coordinator.admittedCount, 0);
  });

  test('in-flight set holds the admission until persistence lands', () async {
    final coordinator = AccountWriteBackCoordinator();
    final account = _GatedPersistenceAccount();
    await Accounts.installCredentials(account);
    final hold = account.holdNextPersistence();
    final selecting = Accounts.set(
      AccountType.recommend,
      account,
      coordinator: coordinator,
    );
    await hold.started.future;
    expect(coordinator.liveOperationCount, 1);
    var drained = false;
    final drain = coordinator.freeze()
      ..then((_) => drained = true);
    await Future<void>.value();
    expect(drained, false);
    account.releasePersistence(hold);
    await selecting;
    await drain;
    expect(drained, true);
    expect(Accounts.get(AccountType.recommend), same(account));
    expect(account.type.contains(AccountType.recommend), true);
    expect(coordinator.liveOperationCount, 0);
  });

  test('an injected unfrozen coordinator keeps selection working', () async {
    final coordinator = AccountWriteBackCoordinator();
    final account = _account(940131);
    await Accounts.installCredentials(account);
    await Accounts.set(
      AccountType.recommend,
      account,
      coordinator: coordinator,
    );
    expect(Accounts.get(AccountType.recommend), same(account));
    expect(account.type.contains(AccountType.recommend), true);
    expect(coordinator.liveOperationCount, 0);
  });
}
