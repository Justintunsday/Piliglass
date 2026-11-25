import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_http/native_http_request_lease_bridge.dart';
import 'package:PiliPlus/services/native_http/native_http_request_lease_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_request_state.dart';

enum _Scenario { split, switchAccount, revoke }

final class _ProbeRun {
  _ProbeRun(this.scenario, this.original, this.main, this.guestStamp);

  final _Scenario scenario;
  final Account original;
  final Account main;
  final AccountRequestStamp<Account> guestStamp;
  String? requestID;
  int heads = 0;
  int writeBacks = 0;
  bool guestOnly = true;
  Map<String, Object?>? receipt;
}

/// Lives only in the device acceptance branch. Selection is process-local.
final class NativeTrendingDeviceProbe {
  late final requests = NativeHTTPRequestLeaseBridge(
    service: NativeHTTPRequestLeaseService(
      awaitCookieSave: (owner, _, saving) async {
        final run = _run;
        if (run != null) {
          run.writeBacks++;
          run.guestOnly &= identical(owner, run.guestStamp.account);
        }
        await saving;
      },
    ),
  );

  _ProbeRun? _run;

  Object command(Object? arguments) {
    if (arguments case {'phase': final String phase}) {
      return switch (phase) {
        'split' => _begin(_Scenario.split),
        'switch' => _begin(_Scenario.switchAccount),
        'revoke' => _begin(_Scenario.revoke),
        'head' => _afterHead(),
        'end' => _end(),
        _ => throw StateError('Unknown trending probe checkpoint'),
      };
    }
    throw StateError('Missing trending probe checkpoint');
  }

  String _begin(_Scenario scenario) {
    final main = Accounts.main;
    final guest = AnonymousAccount();
    final stamp = Accounts.captureRequest(guest);
    if (_run != null ||
        requests.service.liveLeaseCount != 0 ||
        main is! LoginAccount ||
        !Accounts.ownsCredentials(main) ||
        stamp == null) {
      throw StateError('Trending probe requires an idle signed-in test app');
    }
    final original = Accounts.accountMode[AccountType.recommend.index];
    Accounts.selectTemporarily(AccountType.recommend, guest);
    _run = _ProbeRun(scenario, original, main, stamp);
    return 'armed';
  }

  String _afterHead() {
    final run = _run;
    if (run == null) return 'idle';
    if (run.requestID == null ||
        run.heads != 0 ||
        requests.service.liveLeaseCount != 1 ||
        requests.service.finishingLeaseCount != 0 ||
        !identical(Accounts.main, run.main) ||
        !Accounts.isCurrentRequest(run.guestStamp)) {
      throw StateError(
        'The split-owner request did not reach the live checkpoint',
      );
    }
    run.heads++;
    switch (run.scenario) {
      case _Scenario.split:
        break;
      case _Scenario.switchAccount:
        Accounts.selectTemporarily(AccountType.recommend, run.main);
      case _Scenario.revoke:
        final guest = AnonymousAccount();
        final reset = Accounts.beginAnonymousReset(guest);
        try {
          if (Accounts.isCurrentRequest(run.guestStamp)) {
            throw StateError('The anonymous generation was not revoked');
          }
        } finally {
          Accounts.completeAnonymousReset(guest, reset);
        }
        if (Accounts.isCurrentRequest(run.guestStamp) ||
            Accounts.captureRequest(guest) == null) {
          throw StateError('The old lease became current again');
        }
    }
    return 'checkpoint';
  }

  Future<Map<String, Object?>> handleLease(
    String method,
    Object? arguments,
  ) async {
    final run = _run;
    if (run == null || arguments is! Map) {
      return requests.handle(method, arguments);
    }
    if (method == 'prepareNativeHTTPRequest') {
      final reply = await requests.handle(method, arguments);
      if (run.requestID != null ||
          reply['state'] != 'prepared' ||
          reply['generation'] != run.guestStamp.generation) {
        throw StateError(
          'The native request did not use the recommendation owner',
        );
      }
      run.requestID = arguments['requestID'] as String;
      return reply;
    }
    if (method == 'finishNativeHTTPRequest' &&
        arguments['requestID'] == run.requestID) {
      final response = arguments['response'] as Map;
      // An expired canary exercises the real writer without persisting a field
      // or feeding live server Set-Cookie values into this ownership probe.
      final reply = await requests.handle(method, {
        ...arguments,
        'response': {
          ...response,
          'setCookieValues': [
            'piliglass_trending_device_acceptance_canary=0; Max-Age=0; Path=/x/v2/search/trending',
          ],
        },
      });
      run.receipt = reply;
      return reply;
    }
    return requests.handle(method, arguments);
  }

  Map<String, Object?> _end() {
    final run = _run;
    if (run == null) throw StateError('No active trending probe');
    _run = null;
    Accounts.selectTemporarily(AccountType.recommend, run.original);
    return {
      'receipt': run.receipt?['state'] ?? 'missing',
      'cookiesSaved': run.receipt?['cookiesSaved'] ?? false,
      'cookieCount': run.receipt?['cookieCount'] ?? 0,
      'heads': run.heads,
      'writeBacks': run.writeBacks,
      'guestOnly': run.guestOnly,
      'leaseReleased': requests.service.liveLeaseCount == 0,
      'accountRestored':
          identical(Accounts.main, run.main) &&
          identical(
            Accounts.accountMode[AccountType.recommend.index],
            run.original,
          ) &&
          Accounts.ownsCredentials(run.main),
    };
  }
}
