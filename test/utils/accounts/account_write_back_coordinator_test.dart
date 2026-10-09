import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/account_write_back_coordinator.dart';
import 'package:PiliPlus/services/native_http/native_http_request_lease_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/accounts/account_manager/response_cookie_headers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

int _nextID = 0;
String _requestID() =>
    '00000000-0000-4000-8000-${(++_nextID).toRadixString(16).padLeft(12, '0')}';

LoginAccount _account(int mid) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'bili_jct': 'csrf-$mid',
    'SESSDATA': 'session-$mid',
  }),
  'access-$mid',
  'refresh-$mid',
)..activated = true;

Matcher _leaseError(String code) => isA<NativeHTTPRequestLeaseException>()
    .having((error) => error.code, 'lease error code', code);

Future<String?> _cookie(Account account, String name) async {
  final cookies = await account.cookieJar.loadForRequest(
    Uri.parse('https://api.bilibili.com/x/trending'),
  );
  for (final cookie in cookies) {
    if (cookie.name == name) return cookie.value;
  }
  return null;
}

NativeHTTPRequestLeaseResponse _response(NativeHTTPRequestLeaseSnapshot snapshot) =>
    NativeHTTPRequestLeaseResponse(
      url: snapshot.url,
      statusCode: 200,
      cookieSource: SetCookieSource.separatedFields,
      setCookieValues: const ['lease_cookie=received; Path=/'],
    );

void main() {
  group('AccountWriteBackCoordinator', () {
    test('admission is one-shot idempotent and freeze rejects new operations', () async {
      final coordinator = AccountWriteBackCoordinator();
      expect(coordinator.isFrozen, false);
      final first = coordinator.tryAdmit()!;
      expect(coordinator.admittedCount, 1);
      expect(coordinator.liveOperationCount, 1);
      first.release();
      first.release();
      expect(first.isReleased, true);
      expect(coordinator.admittedCount, 0);
      expect(coordinator.liveOperationCount, 0);
      await coordinator.freeze();
      expect(coordinator.isFrozen, true);
      expect(coordinator.tryAdmit(), isNull);
    });

    test('freeze waits for every admitted chain and each waiter completes once', () async {
      final coordinator = AccountWriteBackCoordinator();
      final outer = coordinator.tryAdmit()!;
      final nested = coordinator.tryAdmit()!;
      expect(coordinator.admittedCount, 2);
      var firstDrained = false;
      var secondDrained = false;
      final firstDrain = coordinator.freeze();
      final secondDrain = coordinator.freeze();
      firstDrain.then((_) => firstDrained = true);
      secondDrain.then((_) => secondDrained = true);
      await Future<void>.value();
      expect(firstDrained, false);
      expect(secondDrained, false);
      expect(coordinator.tryAdmit(), isNull);
      nested.release();
      await Future<void>.value();
      expect(firstDrained, false);
      outer.release();
      await Future.wait([firstDrain, secondDrain]);
      expect(firstDrained, true);
      expect(secondDrained, true);
      expect(coordinator.admittedCount, 0);
      expect(coordinator.liveOperationCount, 0);
    });

    test('a throwing chain releases exactly once in finally', () async {
      final coordinator = AccountWriteBackCoordinator();
      final operation = coordinator.tryAdmit()!;
      var drained = false;
      final drain = coordinator.freeze();
      drain.then((_) => drained = true);
      await Future<void>.value();
      expect(drained, false);
      await expectLater(
        Future<void>(() {
          try {
            throw StateError('synthetic chain failure');
          } finally {
            operation.release();
          }
        }),
        throwsStateError,
      );
      await drain;
      expect(drained, true);
      expect(coordinator.liveOperationCount, 0);
    });

    test('production composition shares one coordinator', () {
      expect(
        identical(AccountManager().writeBackCoordinator, accountWriteBackCoordinator),
        true,
      );
      expect(
        identical(
          NativeHTTPRequestLeaseService().writeBackCoordinator,
          accountWriteBackCoordinator,
        ),
        true,
      );
    });
  });

  group('Native HTTP lease finish write-back', () {
    late AccountTestStorage storage;
    late Dio dio;
    final services = <NativeHTTPRequestLeaseService>[];

    setUpAll(() async {
      storage = await AccountTestStorage.open();
    });
    setUp(() async {
      await storage.reset();
      dio = Dio(BaseOptions(
        baseUrl: HttpString.apiBaseUrl,
        headers: {'accept': 'application/json', 'fixture': 'base'},
      ));
    });
    tearDown(() {
      for (final service in services) {
        service.dispose();
      }
      services.clear();
      dio.close(force: true);
    });
    tearDownAll(() => storage.close());

    NativeHTTPRequestLeaseService create({
      required AccountWriteBackCoordinator coordinator,
      Future<void> Function(Account, Uri, Future<void>)? awaitCookieSave,
      Future<void> Function(Account, Future<void>?)? awaitAccountPersistence,
    }) {
      final service = NativeHTTPRequestLeaseService(
        options: () => dio.options,
        awaitCookieSave: awaitCookieSave,
        awaitAccountPersistence: awaitAccountPersistence,
        writeBackCoordinator: coordinator,
        autoExpire: false,
      );
      services.add(service);
      return service;
    }

    Future<LoginAccount> select(int mid) async {
      final account = _account(mid);
      await Accounts.installCredentials(account);
      await Accounts.set(AccountType.recommend, account);
      return account;
    }

    test('cookie await is covered and drained only after the chain finishes', () async {
      final coordinator = AccountWriteBackCoordinator();
      final account = await select(910001);
      final gate = Completer<void>();
      final saveStarted = Completer<void>();
      final service = create(
        coordinator: coordinator,
        awaitCookieSave: (owner, uri, saving) async {
          if (!saveStarted.isCompleted) saveStarted.complete();
          await saving;
          await gate.future;
        },
      );
      final snapshot = await service.prepare(requestID: _requestID());
      final finishing = service.finish(
        requestID: snapshot.requestID,
        leaseID: snapshot.leaseID,
        response: _response(snapshot),
      );
      await saveStarted.future;
      expect(coordinator.liveOperationCount, 1);
      var drained = false;
      final drain = coordinator.freeze();
      drain.then((_) => drained = true);
      await Future<void>.value();
      expect(drained, false);
      expect(coordinator.tryAdmit(), isNull);
      gate.complete();
      final receipt = await finishing;
      expect(receipt.outcome, NativeHTTPRequestLeaseOutcome.finished);
      expect(await _cookie(account, 'lease_cookie'), 'received');
      await drain;
      expect(drained, true);
      expect(coordinator.liveOperationCount, 0);
    });

    test('persistence await is covered by the same admission', () async {
      final coordinator = AccountWriteBackCoordinator();
      final account = await select(910002);
      final gate = Completer<void>();
      final persistenceStarted = Completer<void>();
      final service = create(
        coordinator: coordinator,
        awaitAccountPersistence: (owner, saving) async {
          if (!persistenceStarted.isCompleted) persistenceStarted.complete();
          await saving;
          await gate.future;
        },
      );
      final snapshot = await service.prepare(requestID: _requestID());
      final finishing = service.finish(
        requestID: snapshot.requestID,
        leaseID: snapshot.leaseID,
        response: _response(snapshot),
      );
      await persistenceStarted.future;
      expect(coordinator.liveOperationCount, 1);
      var drained = false;
      final drain = coordinator.freeze();
      drain.then((_) => drained = true);
      await Future<void>.value();
      expect(drained, false);
      gate.complete();
      final receipt = await finishing;
      expect(receipt.outcome, NativeHTTPRequestLeaseOutcome.finished);
      await drain;
      expect(drained, true);
      expect(coordinator.liveOperationCount, 0);
    });

    test('frozen admission rejects finish with zero jar writes', () async {
      final coordinator = AccountWriteBackCoordinator();
      final account = await select(910003);
      final service = create(coordinator: coordinator);
      final snapshot = await service.prepare(requestID: _requestID());
      final before = jsonEncode(account.cookieJar.toJson());
      await coordinator.freeze();
      final receipt = await service.finish(
        requestID: snapshot.requestID,
        leaseID: snapshot.leaseID,
        response: _response(snapshot),
      );
      expect(receipt.outcome, NativeHTTPRequestLeaseOutcome.revoked);
      expect(receipt.cookiesSaved, false);
      expect(jsonEncode(account.cookieJar.toJson()), before);
      expect(coordinator.admittedCount, 0);
    });

    test('persistence throw releases once and later freeze drains immediately', () async {
      final coordinator = AccountWriteBackCoordinator();
      final account = await select(910004);
      final failure = StateError('synthetic persistence failure');
      final service = create(
        coordinator: coordinator,
        awaitAccountPersistence: (owner, saving) async {
          await saving;
          throw failure;
        },
      );
      final snapshot = await service.prepare(requestID: _requestID());
      await expectLater(
        service.finish(
          requestID: snapshot.requestID,
          leaseID: snapshot.leaseID,
          response: _response(snapshot),
        ),
        throwsA(_leaseError('persistenceFailed')),
      );
      expect(coordinator.admittedCount, 0);
      expect(coordinator.liveOperationCount, 0);
      await coordinator.freeze();
    });

    test('abandon and dispose clear tables but never release the in-flight admission', () async {
      final coordinator = AccountWriteBackCoordinator();
      final account = await select(910005);
      final gate = Completer<void>();
      final saveStarted = Completer<void>();
      final service = create(
        coordinator: coordinator,
        awaitCookieSave: (owner, uri, saving) async {
          if (!saveStarted.isCompleted) saveStarted.complete();
          await saving;
          await gate.future;
        },
      );
      final snapshot = await service.prepare(requestID: _requestID());
      final finishing = service.finish(
        requestID: snapshot.requestID,
        leaseID: snapshot.leaseID,
        response: _response(snapshot),
      );
      await saveStarted.future;
      expect(
        service.abandon(requestID: snapshot.requestID, leaseID: snapshot.leaseID).outcome,
        NativeHTTPRequestLeaseOutcome.consumed,
      );
      service.dispose();
      var drained = false;
      final drain = coordinator.freeze();
      drain.then((_) => drained = true);
      await Future<void>.value();
      expect(drained, false);
      expect(coordinator.liveOperationCount, 1);
      gate.complete();
      final receipt = await finishing;
      expect(receipt.outcome, NativeHTTPRequestLeaseOutcome.closed);
      await drain;
      expect(drained, true);
      expect(coordinator.liveOperationCount, 0);
    });
  });
}
