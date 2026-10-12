import 'dart:async';
import 'dart:io' show Cookie, Platform;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/main.dart' show webViewEnvironment;
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/services/native_accounts/account_write_back_coordinator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_request_state.dart';
import 'package:PiliPlus/utils/request_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:collection/collection.dart';
import 'package:PiliPlus/utils/linux_cookie_manager.dart';
import 'package:crypto/crypto.dart' show Digest;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as web;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

abstract final class LoginUtils {
  /// Test seam: performs the WebView mirror writes for one owner. [isCurrent]
  /// is checked before every cookie write; production uses the real
  /// CookieManager and never writes for a stale owner. Tests replace and
  /// restore it.
  static Future<void> Function(
    Account account,
    List<Cookie> cookies,
    bool Function() isCurrent,
  ) webCookieMirrorWriter = _writeWebCookies;

  /// Test seam for the logout-side WebView cookie clear.
  static Future<void> Function() webCookieClearer = _clearWebCookies;

  /// Test seam for the shared UI/cache publication after a successful login
  /// check. Production updates AccountService, the toast and userInfoCache.
  static Future<void> Function(UserInfoData response) loginMainPublisher =
      _publishLoginMain;

  /// FIFO serialization for WebView mirror effects so a stale in-flight login
  /// mirror can never finish after a newer logout/login state.
  static Future<void> _webCookieQueue = Future<void>.value();

  static Future<T> _runWebCookieExclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _webCookieQueue = _webCookieQueue.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  static Future<void> _writeWebCookies(
    Account account,
    List<Cookie> cookies,
    bool Function() isCurrent,
  ) async {
    if (Platform.isLinux) return;
    final webManager = web.CookieManager.instance(
      webViewEnvironment: webViewEnvironment,
    );
    for (final cookie in cookies) {
      if (!isCurrent()) return;
      await webManager.setCookie(
        url: web.WebUri(
          '${Platform.isWindows ? 'https://' : ''}${cookie.domain}',
        ),
        name: cookie.name,
        value: cookie.value,
        path: cookie.path ?? '/',
        domain: cookie.domain,
        isSecure: cookie.secure,
        isHttpOnly: cookie.httpOnly,
      );
    }
  }

  static Future<void> _clearWebCookies() async {
    if (Platform.isLinux) {
      await LinuxCookieManager.deleteAllCookies();
      return;
    }
    await web.CookieManager.instance(
      webViewEnvironment: webViewEnvironment,
    ).deleteAllCookies();
  }

  static Future<void> _publishLoginMain(UserInfoData response) async {
    final accountService = Get.find<AccountService>()
      ..face.value = response.face!;

    if (accountService.isLogin.value) {
      accountService.isLogin.refresh();
    } else {
      accountService.isLogin.value = true;
    }

    SmartDialog.showToast('main登录成功');
    if (response != Pref.userInfoCache) {
      await GStorage.userInfo.put('userInfoCache', response);
    }
  }

  static bool _isCurrentMain(Account account, AccountRequestStamp<Account> stamp) =>
      identical(Accounts.main, account) &&
      identical(stamp.account, account) &&
      Accounts.isCurrentRequest(stamp);

  /// Mirrors [account]'s cookies into the WebView store. Admitted and
  /// serialized like every other write chain: stale owners stop before the
  /// first write and between writes, and the FIFO keeps a newer logout/login
  /// effect last.
  static Future<void> setWebCookie({
    Account? account,
    AccountWriteBackOperation? admission,
    AccountWriteBackCoordinator? coordinator,
    AccountRequestStamp<Account>? stamp,
  }) async {
    final writeBack = coordinator ?? accountWriteBackCoordinator;
    final owned = admission == null ? writeBack.tryAdmit() : null;
    if (admission == null && owned == null) {
      throw StateError('Account write-back is frozen');
    }
    try {
      final owner = account ?? Accounts.main;
      // Entry incarnation stamp, not current ownership: a same-object
      // revoke/re-activate (anonymous reset) would make ownsCredentials true
      // again, so queued mirror work must be bound to the generation captured
      // at entry.
      final bound = stamp ?? Accounts.captureRequest(owner);
      if (bound == null || !identical(bound.account, owner)) return;
      bool isCurrent() =>
          identical(Accounts.main, owner) && Accounts.isCurrentRequest(bound);
      if (!isCurrent()) return;
      final cookies = owner.cookieJar.toList();
      await _runWebCookieExclusive(
        () => webCookieMirrorWriter(owner, cookies, isCurrent),
      );
    } finally {
      owned?.release();
    }
  }

  static Future<void> onLoginMain({
    AccountWriteBackOperation? admission,
    AccountWriteBackCoordinator? coordinator,
    Future<LoadingState<UserInfoData>> Function() userInfo = UserHttp.userInfo,
  }) async {
    final writeBack = coordinator ?? accountWriteBackCoordinator;
    final owned = admission == null ? writeBack.tryAdmit() : null;
    if (admission == null && owned == null) {
      throw StateError('Account write-back is frozen');
    }
    final effective = admission ?? owned;
    try {
      final account = Accounts.main;
      final stamp = Accounts.captureRequest(account);
      if (stamp == null) return;
      final res = await userInfo();
      // Admission is lifecycle only, not ownership: every shared effect below
      // is gated on the captured owner/generation still being current.
      if (!_isCurrentMain(account, stamp)) return;
      if (res case Success(:final response)) {
        await setWebCookie(
          account: account,
          admission: effective,
          coordinator: writeBack,
          stamp: stamp,
        );
        if (!_isCurrentMain(account, stamp)) return;
        await RequestUtils.syncHistoryStatus(
          admission: effective,
          coordinator: writeBack,
        );
        if (!_isCurrentMain(account, stamp)) return;
        if (response.isLogin == true) {
          await loginMainPublisher(response);
        }
      } else {
        // 获取用户信息失败
        final errMsg = res.toString();
        if (errMsg == '账号未登录') {
          await Accounts.deleteAll(
            {account},
            admission: effective,
            coordinator: writeBack,
          );
          SmartDialog.showNotify(
            msg: '登录失败，请检查cookie是否正确，$errMsg',
            notifyType: .warning,
          );
        } else {
          SmartDialog.showToast(errMsg);
        }
      }
    } finally {
      owned?.release();
    }
  }

  static Future<void> onLogoutMain({
    AccountWriteBackOperation? admission,
    AccountWriteBackCoordinator? coordinator,
  }) {
    final writeBack = coordinator ?? accountWriteBackCoordinator;
    final owned = admission == null ? writeBack.tryAdmit() : null;
    if (admission == null && owned == null) {
      throw StateError('Account write-back is frozen');
    }
    try {
      Get.find<AccountService>()
        ..face.value = ''
        ..isLogin.value = false;

      return Future.wait([
        _runWebCookieExclusive(webCookieClearer),
        GStorage.userInfo.delete('userInfoCache'),
      ]).whenComplete(() => owned?.release());
    } catch (_) {
      owned?.release();
      rethrow;
    }
  }

  static String generateBuvid() {
    final md5Str = Digest(
      List.generate(16, (_) => Utils.random.nextInt(256)),
    ).toString();
    return 'XY${md5Str[2]}${md5Str[12]}${md5Str[22]}$md5Str';
  }

  static final buvid = Pref.buvid;

  // static String getUUID() {
  //   return const Uuid().v4().replaceAll('-', '');
  // }

  // static String generateBuvid() {
  //   String uuid = getUUID() + getUUID();
  //   return 'XY${uuid.substring(0, 35).toUpperCase()}';
  // }

  static String genDeviceId() {
    // https://github.com/bilive/bilive_client/blob/2873de0532c54832f5464a4c57325ad9af8b8698/bilive/lib/app_client.ts#L62
    final time = DateTime.now();

    final List<int> bytes = [
      ...Iterable.generate(16, (_) => Utils.random.nextInt(256)),
      _dec2bcd(time.year ~/ 100),
      _dec2bcd(time.year % 100),
      _dec2bcd(time.month),
      _dec2bcd(time.day),
      _dec2bcd(time.hour),
      _dec2bcd(time.minute),
      _dec2bcd(time.second),
      ...Iterable.generate(8, (_) => Utils.random.nextInt(256)),
    ];
    final check = (bytes.sum & 0xFF).toRadixString(16).padLeft(2, '0');

    return Digest(bytes).toString() + check;
  }

  static int _dec2bcd(int dec) {
    assert(0 <= dec && dec < 100);
    return ((dec ~/ 10) << 4) | (dec % 10);
  }
}
