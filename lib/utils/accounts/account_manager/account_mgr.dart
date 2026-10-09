// edit from package:dio_cookie_manager
import 'dart:io';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/account_cookie_mutation_port.dart';
import 'package:PiliPlus/services/native_accounts/account_credential_reader.dart';
import 'package:PiliPlus/services/native_accounts/account_write_back_coordinator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/response_cookie_headers.dart';
import 'package:PiliPlus/utils/accounts/account_request_state.dart';
import 'package:PiliPlus/utils/accounts/api_type.dart';
import 'package:PiliPlus/utils/app_sign.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

class AccountManager extends Interceptor {
  AccountManager({
    AccountWriteBackCoordinator? writeBackCoordinator,
    AccountCredentialReader? credentialReader,
  })  : writeBackCoordinator =
            writeBackCoordinator ?? accountWriteBackCoordinator,
        credentialReader = credentialReader ?? accountCredentialReader;

  /// Shared admission/drain gate for response write-back; composition only.
  /// It does not replace owner/generation checks in this class.
  final AccountWriteBackCoordinator writeBackCoordinator;

  /// Read-only credential context provider for request header assembly.
  final AccountCredentialReader credentialReader;

  static const _bindingKey = '_piliglassAccountRequestBinding';
  static String blockServer = Pref.blockServer;

  static String getCookies(List<Cookie> cookies) {
    // Sort cookies by path (longer path first).
    cookies.sort((a, b) {
      if (a.path == null && b.path == null) {
        return 0;
      } else if (a.path == null) {
        return -1;
      } else if (b.path == null) {
        return 1;
      } else {
        return b.path!.length.compareTo(a.path!.length);
      }
    });
    return cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.path;

    final binding = _bindRequestAccount(options);
    final account = binding.account;

    if (account is NoAccount || _skipCookie(path)) return handler.next(options);
    final stamp = binding.stamp;
    if (stamp == null || !_isCurrentBinding(binding, options)) {
      return handler.reject(_revokedRequest(options), false);
    }
    // Read-only credential context for the already-bound owner/generation.
    // A null result keeps the existing revoked handling; the context does not
    // authorize the request and owner checks above still govern it.
    final credentials = credentialReader.captureRequest(account, stamp);
    if (credentials == null) {
      return handler.reject(_revokedRequest(options), false);
    }

    if (!credentials.isLogin && path == Api.heartBeat) {
      return handler.reject(
        DioException.requestCancelled(requestOptions: options, reason: null),
        false,
      );
    }

    final isApp = path.startsWith(HttpString.appBaseUrl);

    if (isApp && options.responseType == ResponseType.bytes) {
      options.headers.addAll(credentials.grpcHeaders);
      return handler.next(options);
    }

    options.headers
      ..addAll(credentials.headers)
      ..['referer'] ??= HttpString.baseUrl;

    // app端不需要管理cookie
    if (isApp) {
      // if (kDebugMode) debugPrint('is app: ${options.path}');
      final dataPtr = (options.method == 'POST' && options.data is Map
          ? (options.data as Map).cast<String, dynamic>()
          : options.queryParameters);
      if (dataPtr.isNotEmpty) {
        final accessKey = credentials.accessKey;
        if (!accessKey.isNullOrEmpty) {
          dataPtr['access_key'] = accessKey!;
        }
        AppSign.appSign(dataPtr..remove('sign'));
        // if (kDebugMode) debugPrint(dataPtr.toString());
      }
      return handler.next(options);
    } else {
      account.cookieJar
          .loadForRequest(options.uri)
          .then((cookies) {
            if (!_isCurrentBinding(binding, options)) {
              handler.reject(_revokedRequest(options), false);
              return;
            }
            final previousCookies =
                options.headers[HttpHeaders.cookieHeader] as String?;
            final newCookies = getCookies([
              ...?previousCookies
                  ?.split(';')
                  .where((e) => e.isNotEmpty)
                  .map(Cookie.fromSetCookieValue),
              ...cookies,
            ]);
            options.headers[HttpHeaders.cookieHeader] = newCookies.isNotEmpty
                ? newCookies
                : '';
            handler.next(options);
          })
          .catchError((Object e, StackTrace s) {
            final err = DioException(
              requestOptions: options,
              error: e,
              stackTrace: s,
            );
            handler.reject(err, true);
          });
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (_boundRequestAccount(response.requestOptions) case final binding?) {
      final future = _saveCookies(
        binding,
        response,
        writeBackCoordinator,
      ).whenComplete(() => handler.next(response));
      assert(() {
        future.catchError(
          (Object e, StackTrace s) {
            throw DioException(
              requestOptions: response.requestOptions,
              error: e,
              stackTrace: s,
            );
          },
        );
        return true;
      }());
    } else {
      return handler.next(response);
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final options = err.requestOptions;
    if (options.responseType == ResponseType.stream) {
      return handler.next(err);
    }

    if (options.method != 'POST') toast(err);

    if (err.response case final res?) {
      if (_boundRequestAccount(options) case final binding?) {
        _saveCookies(binding, res, writeBackCoordinator).then(
          (_) => handler.next(err),
          onError: (Object e, StackTrace s) => handler.next(
            DioException(
              requestOptions: options,
              error: e,
              stackTrace: s,
            ),
          ),
        );
        return;
      }
    }
    return handler.next(err);
  }

  static void toast(DioException err) {
    const skipShow = [
      'heartbeat',
      'history/report',
      'roomEntryAction',
      'seg.so',
      'online/total',
      'github',
      'hdslb.com',
      'biliimg.com',
      'site/getCoin',
    ];
    String url = err.requestOptions.uri.toString();
    if (kDebugMode) debugPrint('🌹🌹ApiInterceptor: $url\n$err');
    if (skipShow.any(url.contains) ||
        (url.contains('skipSegments') && err.requestOptions.method == 'GET')) {
      // skip
    } else {
      dioError(err).then((res) => SmartDialog.showToast(res + url));
    }
  }

  static Future<void> _saveCookies(
    _RequestAccountBinding binding,
    Response response,
    AccountWriteBackCoordinator coordinator,
  ) async {
    final options = response.requestOptions;
    if (!_isCurrentBinding(binding, options)) return;
    final account = binding.account;
    final setCookies = response.headers[HttpHeaders.setCookieHeader];
    if (setCookies == null || setCookies.isEmpty) {
      return;
    }
    final cookies = parseResponseCookieHeaders(
      setCookies,
      source: SetCookieSource.dioLegacyPossiblyFolded,
    ).cookies;
    final statusCode = response.statusCode ?? 0;
    final locations = response.headers[HttpHeaders.locationHeader] ?? const [];
    final isRedirectRequest = statusCode >= 300 && statusCode < 400;
    final originalUri = response.requestOptions.uri;
    final realUri = originalUri.resolveUri(response.realUri);
    if (!_isCurrentBinding(binding, options)) return;
    // Admission covers every real await below (Cookie save, each redirect
    // save and Hive persistence). Frozen means zero write, never a new bypass.
    final admission = coordinator.tryAdmit();
    if (admission == null) return;
    try {
      final saving = accountCookieMutationPort.saveResponseCookies(account, realUri, cookies);
      Accounts.notifyCookieMutation(account);
      await saving;
      if (!_isCurrentBinding(binding, options)) return;
      if (isRedirectRequest && locations.isNotEmpty) {
        final originalUri = response.realUri;
        for (final location in locations) {
          if (!_isCurrentBinding(binding, options)) return;
          final redirectSaving = accountCookieMutationPort.saveResponseCookies(
            account,
            // Resolves the location based on the current Uri.
            originalUri.resolve(location),
            cookies,
          );
          Accounts.notifyCookieMutation(account);
          await redirectSaving;
          if (!_isCurrentBinding(binding, options)) return;
        }
      }
      if (!_isCurrentBinding(binding, options)) return;
      await account.onChange();
    } finally {
      admission.release();
    }
  }

  static bool _skipCookie(String path) {
    return path.startsWith(blockServer) ||
        path.contains('hdslb.com') ||
        path.contains('biliimg.com');
  }

  static Account _findAccount(String path) => ApiType.loginApi.contains(path)
      ? AnonymousAccount()
      : Accounts.get(
          AccountType.values.firstWhere(
            (i) => ApiType.apiTypeSet[i]?.contains(path) == true,
            orElse: () => AccountType.main,
          ),
        );

  static _RequestAccountBinding _bindRequestAccount(RequestOptions options) {
    // A retry/redirect keeps the first binding, even if that generation was
    // revoked. Never recapture an anonymous singleton's new credentials here.
    if (options.extra[_bindingKey] case final _RequestAccountBinding binding) {
      return binding;
    }
    assert(options.extra['account'] is Account?);
    final Account account = options.extra['account'] ??= _findAccount(options.path);
    final binding = _RequestAccountBinding(account, Accounts.captureRequest(account));
    options.extra[_bindingKey] = binding;
    return binding;
  }

  static _RequestAccountBinding? _boundRequestAccount(RequestOptions options) {
    final path = options.path;
    final binding = options.extra[_bindingKey];
    if (binding is! _RequestAccountBinding) return null;
    final account = binding.account;
    if (account is NoAccount ||
        path.startsWith(HttpString.appBaseUrl) ||
        _skipCookie(path)) {
      return null;
    }
    return binding;
  }

  static bool _isCurrentBinding(
    _RequestAccountBinding binding,
    RequestOptions options,
  ) {
    final stamp = binding.stamp;
    return stamp != null &&
        identical(options.extra['account'], binding.account) &&
        identical(stamp.account, binding.account) &&
        Accounts.isCurrentRequest(stamp);
  }

  static DioException _revokedRequest(RequestOptions options) =>
      DioException.requestCancelled(
        requestOptions: options,
        reason: 'Account credentials are no longer current',
      );

  static Future<String> dioError(DioException error) async {
    switch (error.type) {
      case .badCertificate:
        return '证书有误！';
      case .badResponse:
        return '服务器异常，请稍后重试！';
      case .cancel:
        return '请求已被取消，请重新请求';
      case .connectionError:
        return '连接错误，请检查网络设置';
      case .connectionTimeout:
        return '网络连接超时，请检查网络设置';
      case .receiveTimeout:
        return '响应超时，请稍后重试！';
      case .sendTimeout:
        return '发送请求超时，请检查网络设置';
      case .transformTimeout:
        return '转换响应数据超时！';
      case .unknown:
        String desc;
        try {
          desc = PlatformUtils.isMobile
              ? (await Connectivity().checkConnectivity()).first.desc
              : '';
        } catch (_) {
          desc = '';
        }
        return '$desc网络异常 ${error.error}';
    }
  }
}

final class _RequestAccountBinding {
  final Account account;
  final AccountRequestStamp<Account>? stamp;

  const _RequestAccountBinding(this.account, this.stamp);
}

extension _ConnectivityResultExt on ConnectivityResult {
  String get desc => const ['蓝牙', 'Wi-Fi', '局域', '流量', '无', '代理', '其他'][index];
}
