import 'dart:async';

import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/services/native_accounts/account_install_persistence_port.dart';
import 'package:PiliPlus/services/native_accounts/account_write_back_coordinator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:PiliPlus/utils/request_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
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

void main() {
  late AccountTestStorage storage;

  setUpAll(() async {
    storage = await AccountTestStorage.open();
    // GStorage.compact() touches every production box; open the ones the
    // shared fixture leaves closed so the maintenance path is exercised for
    // real (Accounts.account and setting/localCache are already open).
    GStorage.userInfo = await Hive.openBox<UserInfoData>('userInfo');
    GStorage.historyWord = await Hive.openBox<dynamic>('historyWord');
    GStorage.video = await Hive.openBox<dynamic>('video');
    GStorage.watchProgress = await Hive.openBox<int>('watchProgress');
    // Production init assigns reply (box or null) unconditionally; the shared
    // fixture leaves it uninitialized, so the maintenance path needs the null.
    GStorage.reply = null;
  });
  setUp(() => storage.reset());
  tearDownAll(() => storage.close());

  test('quiesce completes immediately when idle and never freezes admissions', () async {
    final coordinator = AccountWriteBackCoordinator();
    await coordinator.quiesce();
    expect(coordinator.isFrozen, false);
    final operation = coordinator.tryAdmit();
    expect(operation, isNotNull);
    operation!.release();
    await coordinator.quiesce();
    expect(coordinator.isFrozen, false);
  });

  test('quiesce waits for admitted chains and extends across new admissions', () async {
    final coordinator = AccountWriteBackCoordinator();
    final first = coordinator.tryAdmit()!;
    var quiesced = false;
    final waiting = coordinator.quiesce()..then((_) => quiesced = true);
    await Future<void>.value();
    expect(quiesced, false);
    final second = coordinator.tryAdmit()!;
    first.release();
    await Future<void>.value();
    expect(quiesced, false);
    expect(coordinator.isFrozen, false);
    second.release();
    await waiting;
    expect(quiesced, true);
    expect(coordinator.liveOperationCount, 0);
  });

  test('maintenance is exclusive immediately and releases on end', () async {
    final coordinator = AccountWriteBackCoordinator();
    final pending = coordinator.beginMaintenance();
    // The token is claimed synchronously before the first await.
    expect(coordinator.tryAdmit(), isNull);
    final token = await pending;
    expect(token, isNotNull);
    expect(coordinator.isMaintenanceActive, true);
    token!.end(permanent: false);
    expect(coordinator.isMaintenanceActive, false);
    final admitted = coordinator.tryAdmit();
    expect(admitted, isNotNull);
    admitted!.release();
  });

  test('maintenance blocks admissions at the last-release boundary', () async {
    final coordinator = AccountWriteBackCoordinator();
    final operation = coordinator.tryAdmit()!;
    var acquired = false;
    final pending = coordinator.beginMaintenance()
      ..then((_) => acquired = true);
    await Future<void>.value();
    expect(acquired, false);
    expect(coordinator.tryAdmit(), isNull);
    operation.release();
    final token = await pending;
    expect(acquired, true);
    expect(coordinator.tryAdmit(), isNull);
    token!.end(permanent: false);
    final admitted = coordinator.tryAdmit();
    expect(admitted, isNotNull);
    admitted!.release();
  });

  test('permanent maintenance close never reopens', () async {
    final coordinator = AccountWriteBackCoordinator();
    final token = (await coordinator.beginMaintenance())!;
    token.end(permanent: true);
    expect(coordinator.isClosed, true);
    expect(coordinator.tryAdmit(), isNull);
    expect(await coordinator.beginMaintenance(), isNull);
  });

  test('maintenance never clears an authority freeze', () async {
    final coordinator = AccountWriteBackCoordinator();
    await coordinator.freeze();
    final token = await coordinator.beginMaintenance();
    expect(token, isNotNull);
    token!.end(permanent: false);
    expect(coordinator.isFrozen, true);
    expect(coordinator.tryAdmit(), isNull);
  });

  test('compact waits for the admitted write chain before touching Hive', () async {
    final coordinator = AccountWriteBackCoordinator();
    final port = _GatedInstallPort();
    final account = _account(970001);
    final installing = Accounts.installCredentials(
      account,
      coordinator: coordinator,
      persistencePort: port,
    );
    await port.started.future;
    var compacted = false;
    final compacting = GStorage.compact(coordinator: coordinator)
      ..then((_) => compacted = true);
    await Future<void>.value();
    expect(compacted, false);
    expect(coordinator.liveOperationCount, 1);
    // The maintenance barrier rejects admissions while it owns the boxes.
    expect(coordinator.tryAdmit(), isNull);
    port.gate.complete();
    await installing;
    await compacting;
    expect(compacted, true);
    expect(Accounts.account.get('970001'), same(account));
    expect(Accounts.account.isOpen, true);
    // Compaction resumes admissions after it ends.
    final admitted = coordinator.tryAdmit();
    expect(admitted, isNotNull);
    admitted!.release();
  });

  test('delayed side effects reject before WK, network or GetX when frozen', () async {
    final coordinator = AccountWriteBackCoordinator();
    await coordinator.freeze();
    expect(
      () => LoginUtils.setWebCookie(null, null, coordinator),
      throwsStateError,
    );
    await expectLater(
      RequestUtils.syncHistoryStatus(coordinator: coordinator),
      throwsStateError,
    );
    await expectLater(
      LoginUtils.onLoginMain(coordinator: coordinator),
      throwsStateError,
    );
    expect(
      () => LoginUtils.onLogoutMain(coordinator: coordinator),
      throwsStateError,
    );
  });

  test('syncHistoryStatus reuses an outer admission without releasing it', () async {
    final coordinator = AccountWriteBackCoordinator();
    final operation = coordinator.tryAdmit()!;
    // No login account is installed, so the chain returns before the network.
    await RequestUtils.syncHistoryStatus(
      admission: operation,
      coordinator: coordinator,
    );
    expect(coordinator.liveOperationCount, 1);
    operation.release();
    expect(coordinator.liveOperationCount, 0);
  });
}
