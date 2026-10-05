import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/login.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/native_account_snapshot_service.dart';
import 'package:PiliPlus/services/native_login/native_login_authority.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:encrypt/encrypt.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../utils/accounts/account_test_storage.dart';

const _cookie = 'DedeUserID=910001; bili_jct=synthetic-csrf; SESSDATA=synthetic=session==';
const _risk = 'https://passport.bilibili.com/h5-app/passport/risk/verify?tmp_token=synthetic-tmp&request_id=synthetic-request&source=risk';
const _challenge = 'https://passport.bilibili.com/captcha?gee_gt=synthetic-gt&gee_challenge=synthetic-challenge&recaptcha_token=synthetic-token';

Map<String, Object?> _credentials({bool nested = true}) {
  final token = {'access_token': 'synthetic-access', 'refresh_token': 'synthetic-refresh'};
  return {
    if (nested) 'token_info': token else ...token,
    'cookie_info': {'cookies': [
      {'name': 'DedeUserID', 'value': '910001'}, {'name': 'bili_jct', 'value': 'synthetic-csrf'},
      {'name': 'SESSDATA', 'value': 'synthetic=session=='},
    ]},
  };
}

void main() {
  late AccountTestStorage storage;
  late _CaptureAdapter adapter;
  late Map<String, dynamic> rsa;
  setUpAll(() async {
    storage = await AccountTestStorage.open();
    adapter = _CaptureAdapter();
    Request.dio.httpClientAdapter = adapter;
    rsa = jsonDecode(await File('tool/native_login_synthetic_rsa.json').readAsString());
  });
  tearDownAll(() async { await storage.close(); });

  test('actual LoginHttp and Dio export synthetic endpoint/body/response goldens', () async {
    final cases = <Map<String, Object?>>[];
    Future<void> capture(String operation, Map<String, Object?> response, Future<Object?> Function() call) async {
      adapter.response = response;
      adapter.last = null;
      final result = await call();
      final request = adapter.last!;
      final fields = request['fields'] as Map<String, Object?>;
      final ts = fields['ts'];
      int? milliseconds;
      if (operation == 'smsSend' || operation == 'smsChallengeFallback') {
        final seconds = int.parse(ts! as String);
        for (int candidate = (seconds - 1) * 1000; candidate < (seconds + 1) * 1000; candidate++) {
          final digest = md5.convert(ascii.encode(LoginHttp.buvid + candidate.toString())).toString();
          if (digest == fields['login_session_id']) { milliseconds = candidate; break; }
        }
        expect(milliseconds, isNotNull, reason: 'recover actual LoginHttp timestamp, do not invent oracle time');
      }
      final actualStatus = result is Map ? result['status'] : result is LoadingState ? result.isSuccess : null;
      cases.add({'operation': operation, 'response': response, 'dartStatus': actualStatus, 'request': request,
                 'epochSeconds': ts == null ? 1900000000 : int.parse(ts as String),
                 'epochMilliseconds': milliseconds ?? (ts == null ? 1900000000000 : int.parse(ts as String) * 1000)});
    }
    Map<String, Object?> ok(Object? data) => {'code': 0, 'message': '0', 'data': data};
    await capture('qrCreate', ok({'auth_code': 'synthetic-auth', 'url': 'https://passport.bilibili.com/qr?auth=synthetic'}), LoginHttp.getHDcode);
    await capture('qrPoll', ok(_credentials(nested: false)), () => LoginHttp.codePoll('synthetic-auth'));
    await capture('qrWaiting', {'code': 86039, 'message': 'waiting', 'data': null}, () => LoginHttp.codePoll('synthetic-auth'));
    await capture('qrExpired', {'code': 86038, 'message': 'expired', 'data': null}, () => LoginHttp.codePoll('synthetic-auth'));
    await capture('webKey', ok({'hash': 'synthetic-salt', 'key': rsa['publicPEM']}), LoginHttp.getWebKey);
    Future<Object?> pwd() => LoginHttp.loginByPwd(username: '用户 +!()=&', password: 'synthetic-pwd',
        key: rsa['publicPEM'], salt: 'synthetic-salt', geeChallenge: 'synthetic-challenge',
        geeSeccode: 'synthetic-seccode', geeValidate: 'synthetic-validate', recaptchaToken: 'synthetic-token');
    await capture('password', ok(_credentials()), pwd);
    await capture('passwordPhone', ok({'status': 2, 'message': 'risk', 'url': _risk}), pwd);
    await capture('passwordChallenge', {'code': -105, 'message': 'captcha', 'data': {'url': _challenge}}, pwd);
    await capture('passwordMissingCredentials', ok(null), pwd);
    await capture('passwordFailure', {'code': -629, 'message': 'incorrect', 'data': null}, pwd);
    Future<Object?> send() => LoginHttp.sendSmsCode(cid: 86, tel: 'synthetic +%=&',
        geeChallenge: 'synthetic-challenge', geeSeccode: 'synthetic-seccode',
        geeValidate: 'synthetic-validate', recaptchaToken: 'synthetic-token');
    await capture('smsSend', ok({'captcha_key': 'synthetic-sms-key', 'recaptcha_url': ''}), send);
    await capture('smsChallengeFallback', ok({'captcha_key': '', 'recaptcha_url': _challenge}), send);
    await capture('smsLogin', ok(_credentials()), () => LoginHttp.loginBySms(captchaKey: 'synthetic-sms-key',
        tel: 'synthetic +%=&', code: '123456', cid: 86, key: rsa['publicPEM']));
    await capture('phoneInfo', ok({'account_info': {'hide_tel': '123****4567', 'hide_mail': 'a***@x', 'tel_verify': true}}),
        () => LoginHttp.safeCenterGetInfo(tmpCode: 'synthetic-tmp'));
    await capture('preCapture', ok({'gee_gt': 'synthetic-gt', 'gee_challenge': 'synthetic-challenge', 'recaptcha_token': 'synthetic-token'}), LoginHttp.preCapture);
    await capture('phoneSMSSend', ok({'captcha_key': 'synthetic-phone-key'}), () => LoginHttp.safeCenterSmsCode(
        tmpCode: 'synthetic-tmp', geeChallenge: 'synthetic-challenge', geeSeccode: 'synthetic-seccode',
        geeValidate: 'synthetic-validate', recaptchaToken: 'synthetic-token', refererUrl: _risk));
    await capture('phoneSMSVerify', ok({'code': 'synthetic-oauth'}), () => LoginHttp.safeCenterSmsVerify(
        code: '123456', tmpCode: 'synthetic-tmp', requestId: 'synthetic-request', source: 'risk',
        captchaKey: 'synthetic-phone-key', refererUrl: _risk));
    await capture('oauthAccessToken', ok(_credentials()), () => LoginHttp.oauth2AccessToken(code: 'synthetic-oauth'));
    final account = LoginAccount(BiliCookieJar.fromJson({'DedeUserID': '910001', 'bili_jct': 'synthetic-csrf', 'SESSDATA': 'synthetic-session'}), null, null);
    await capture('logout', ok(null), () => LoginHttp.logout(account));
    // Same Cookie-validation request as the current controller; no account UI.
    await capture('cookieValidate', ok({'mid': 910001}), () => Request().get('/x/member/web/account',
        options: Options(headers: {'cookie': _cookie}, extra: {'account': AnonymousAccount()})));

    dynamic privateKey = RSAKeyParser().parse(rsa['privatePKCS1PEM']);
    final decryptor = Encrypter(RSA(privateKey: privateKey));
    for (final entry in cases.where((entry) => (entry['operation'] as String).startsWith('password'))) {
      final fields = (entry['request'] as Map)['fields'] as Map;
      expect(decryptor.decrypt(Encrypted.fromBase64(fields['password'])), 'synthetic-saltsynthetic-pwd');
      expect(decryptor.decrypt(Encrypted.fromBase64(Uri.decodeComponent(fields['dt']))), matches(RegExp('^[0-9a-z]{16}\$')));
    }
    final output = File('build/native-login-contract/dart-goldens.json');
    await output.parent.create(recursive: true);
    await output.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'source': 'actual LoginHttp / Dio / encrypt / Hive synthetic fixture', 'cases': cases,
      'buvid': LoginHttp.buvid, 'deviceID': LoginHttp.deviceId, 'appKey': Constants.appKey, 'appSecret': Constants.appSec,
    }));
    expect(cases, hasLength(20));
  });

  test('single Dart authority preserves selection and rejects old same-MID logout', () async {
    final snapshots = NativeAccountSnapshotService();
    final authority = NativeLoginAuthority(snapshots);
    Map<String, Object?> install(String id) => {
      'operationID': id, 'method': 'cookie', 'purposes': null,
      'credentials': {'mid': 920001, 'accessToken': null, 'refreshToken': null, 'cookies': [
        for (final entry in {'DedeUserID': '920001', 'bili_jct': 'synthetic-csrf', 'SESSDATA': 'synthetic-session'}.entries)
          {'name': entry.key, 'value': entry.value, 'domain': 'bilibili.com', 'path': '/',
           'expiresEpochSeconds': null, 'secure': false, 'httpOnly': false},
      ]},
    };
    final first = await authority.handle('installNativeLoginCredentials', install('install-1'));
    expect(first['state'], 'installed'); expect(first['needsPurposeSelection'], true);
    final second = await authority.handle('installNativeLoginCredentials', install('install-2'));
    expect(second['state'], 'installed'); expect(first['owner'], isNot(second['owner']));
    final stale = await authority.handle('deleteNativeLoginAccounts', {'operationID': 'delete-old', 'owners': [first['owner']]});
    expect(stale['code'], 'staleOwner'); expect(Accounts.account.containsKey('920001'), true);
    final deleted = await authority.handle('deleteNativeLoginAccounts', {'operationID': 'delete-new', 'owners': [second['owner']]});
    expect(deleted['state'], 'deleted'); expect(Accounts.account.containsKey('920001'), false);
    final replay = await authority.handle('installNativeLoginCredentials', install('install-1'));
    expect(replay['code'], 'operationAlreadyConsumed'); expect(Accounts.account.containsKey('920001'), false);
  });

  test('full Cookie attributes cannot silently disappear through old Hive adapter', () async {
    final authority = NativeLoginAuthority(NativeAccountSnapshotService());
    final result = await authority.handle('installNativeLoginCredentials', {
      'operationID': 'attrs', 'method': 'cookie', 'purposes': null,
      'credentials': {'mid': 930001, 'accessToken': null, 'refreshToken': null, 'cookies': [
        {'name': 'DedeUserID', 'value': '930001', 'domain': 'bilibili.com', 'path': '/',
         'expiresEpochSeconds': null, 'secure': true, 'httpOnly': false},
      ]},
    });
    expect(result['code'], 'cookieAttributesNotPersistable'); expect(Accounts.account.containsKey('930001'), false);
  });

  test('explicit purpose assignment remains distinct from preserve-existing login', () async {
    final authority = NativeLoginAuthority(NativeAccountSnapshotService());
    Map<String, Object?> request(String id, Object? purposes) => {
      'operationID': id, 'method': 'cookie', 'purposes': purposes,
      'credentials': {'mid': 940001, 'accessToken': null, 'refreshToken': null, 'cookies': [
        for (final entry in {'DedeUserID': '940001', 'bili_jct': 'synthetic-csrf', 'SESSDATA': 'synthetic-session'}.entries)
          {'name': entry.key, 'value': entry.value, 'domain': 'bilibili.com', 'path': '/',
           'expiresEpochSeconds': null, 'secure': false, 'httpOnly': false},
      ]},
    };
    expect((await authority.handle('installNativeLoginCredentials', request('assign-video', ['video'])))['state'], 'installed');
    final first = Accounts.video;
    expect(first.mid, 940001); expect(Accounts.main.isLogin, false);
    expect((await authority.handle('installNativeLoginCredentials', request('preserve-video', null)))['state'], 'installed');
    expect(identical(first, Accounts.video), false); expect(Accounts.video.mid, 940001);
    expect(Accounts.video.type, {AccountType.video}); expect(Accounts.main.isLogin, false);
  });

  test('same-MID replacement during onChanged cannot acknowledge retired login', () async {
    final snapshots = NativeAccountSnapshotService();
    final entered = Completer<void>(), release = Completer<void>();
    final authority = NativeLoginAuthority(snapshots, onChanged: () async {
      entered.complete(); await release.future;
    });
    final input = _installRequest('refresh-replace', 950001);
    final pending = authority.handle('installNativeLoginCredentials', input);
    await entered.future;
    final retired = Accounts.account.get('950001')!;
    final oldOwner = snapshots.currentOwnerWire(retired)!;
    final successor = _replacement(950001);
    await Accounts.installCredentials(successor);
    final newOwner = snapshots.currentOwnerWire(successor)!;
    expect(newOwner['ownerToken'], isNot(oldOwner['ownerToken']));
    expect(newOwner['generation'], isNot(oldOwner['generation']));
    release.complete();
    expect((await pending)['code'], 'credentialsSuperseded');
    expect(identical(Accounts.account.get('950001'), successor), true);
    expect(Accounts.ownsCredentials(successor), true);
    expect(successor.cookieJar.toJson()['SESSDATA'], 'synthetic-successor');
    expect((await authority.handle('installNativeLoginCredentials', input))['code'], 'operationAlreadyConsumed');
  });

  test('deletion during onChanged cannot acknowledge or resurrect removed login', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final authority = NativeLoginAuthority(NativeAccountSnapshotService(), onChanged: () async {
      entered.complete(); await release.future;
    });
    final input = _installRequest('refresh-delete', 960001);
    final pending = authority.handle('installNativeLoginCredentials', input);
    await entered.future;
    final removed = Accounts.account.get('960001')!;
    await Accounts.deleteAll({removed});
    release.complete();
    expect((await pending)['code'], 'credentialsSuperseded');
    expect(Accounts.account.containsKey('960001'), false);
    expect(Accounts.ownsCredentials(removed), false);
    expect((await authority.handle('installNativeLoginCredentials', input))['code'], 'operationAlreadyConsumed');
    expect(Accounts.account.containsKey('960001'), false);
  });

  test('real Accounts.set activation await cannot assign remaining purposes to successor', () async {
    // Pause only the actual buvid HTTP adapter. Accounts.set, Hive persistence,
    // credential generations and same-MID replacement all run production code.
    adapter.pauseActivation(970001);
    final authority = NativeLoginAuthority(NativeAccountSnapshotService());
    final input = _installRequest('purpose-await-replace', 970001, purposes: ['video', 'recommend']);
    final pending = authority.handle('installNativeLoginCredentials', input);
    try {
      await adapter.activationEntered!.future.timeout(const Duration(seconds: 10));
      final retired = Accounts.video;
      expect(retired.mid, 970001);
      final successor = _replacement(970001);
      await Accounts.installCredentials(successor);
      adapter.resumeActivation();
      expect((await pending)['code'], 'credentialsSuperseded');
      // Existing selection inheritance remains owned by Accounts; the stale
      // login must not add its second requested purpose or roll back successor.
      expect(identical(Accounts.video, successor), true);
      expect(successor.type, {AccountType.video});
      expect(Accounts.get(AccountType.recommend).mid, isNot(970001));
      expect(identical(Accounts.account.get('970001'), successor), true);
      expect(Accounts.ownsCredentials(successor), true);
      expect((await authority.handle('installNativeLoginCredentials', input))['code'], 'operationAlreadyConsumed');
    } finally { adapter.resumeActivation(); await pending; }
  });
}

Map<String, Object?> _installRequest(String operationID, int mid, {List<String>? purposes}) => {
  'operationID': operationID, 'method': 'cookie', 'purposes': purposes,
  'credentials': {'mid': mid, 'accessToken': null, 'refreshToken': null, 'cookies': [
    for (final entry in {'DedeUserID': '$mid', 'bili_jct': 'synthetic-csrf', 'SESSDATA': 'synthetic-original'}.entries)
      {'name': entry.key, 'value': entry.value, 'domain': 'bilibili.com', 'path': '/',
       'expiresEpochSeconds': null, 'secure': false, 'httpOnly': false},
  ]},
};

LoginAccount _replacement(int mid) => LoginAccount(BiliCookieJar.fromJson({
  'DedeUserID': '$mid', 'bili_jct': 'synthetic-successor-csrf', 'SESSDATA': 'synthetic-successor',
}), null, null)..activated = true;

class _CaptureAdapter implements HttpClientAdapter {
  Map<String, Object?> response = {'code': 0, 'data': null};
  Map<String, Object?>? last;
  int? activationMID;
  Completer<void>? activationEntered;
  Completer<void>? _activationRelease;
  void pauseActivation(int mid) {
    activationMID = mid; activationEntered = Completer<void>(); _activationRelease = Completer<void>();
  }
  void resumeActivation() {
    activationMID = null;
    final release = _activationRelease;
    if (release != null && !release.isCompleted) release.complete();
    _activationRelease = null;
  }
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final data = options.data;
    final fields = data is Map ? {for (final entry in data.entries) entry.key.toString(): entry.value.toString()} :
        {for (final entry in options.queryParameters.entries) entry.key: entry.value.toString()};
    final bytes = <int>[];
    if (requestStream != null) { await for (final chunk in requestStream) { bytes.addAll(chunk); } }
    last = {'method': options.method, 'url': options.uri.toString(), 'fields': fields,
            'headers': {for (final entry in options.headers.entries) entry.key: entry.value.toString()},
            'body': utf8.decode(bytes)};
    final owner = options.extra['account'];
    if (options.path == Api.activateBuvidApi && owner is LoginAccount && owner.mid == activationMID) {
      final release = _activationRelease!.future;
      activationEntered!.complete();
      await release;
    }
    return ResponseBody.fromString(jsonEncode(response), 200, headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }
  @override
  void close({bool force = false}) {}
}
