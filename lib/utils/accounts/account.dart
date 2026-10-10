import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/account_cookie_mutation_port.dart';
import 'package:PiliPlus/services/native_accounts/account_deletion_port.dart';
import 'package:PiliPlus/services/native_accounts/account_reset_persistence_port.dart';
import 'package:PiliPlus/services/native_accounts/account_write_back_coordinator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/grpc_headers.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:hive_ce/hive.dart';

sealed class Account {
  Map<String, dynamic>? toJson() => null;

  Future<void>? onChange() => null;

  Set<AccountType> get type => const {};

  bool get activated => false;

  set activated(bool value) => throw UnimplementedError();

  String? get accessKey => throw UnimplementedError();

  DefaultCookieJar get cookieJar => throw UnimplementedError();

  String get csrf => throw UnimplementedError();

  Future<void> delete() => throw UnimplementedError();

  Map<String, String> get headers => throw UnimplementedError();

  Map<String, String> get grpcHeaders => throw UnimplementedError();

  bool get isLogin => throw UnimplementedError();

  int get mid => throw UnimplementedError();

  String? get refresh => throw UnimplementedError();

  const Account();
}

@HiveType(typeId: 9)
class LoginAccount extends Account {
  @override
  final bool isLogin = true;
  @override
  @HiveField(0)
  final DefaultCookieJar cookieJar;
  @override
  @HiveField(1)
  final String? accessKey;
  @override
  @HiveField(2)
  final String? refresh;
  @override
  @HiveField(3)
  final Set<AccountType> type;

  @override
  bool activated = false;

  @override
  late final int mid = _restoredMid ?? int.parse(_midStr);

  final String? _restoredStorageKey;
  final int? _restoredMid;

  @override
  late final Map<String, String> headers = {
    ...Constants.baseHeaders,
    'x-bili-mid': _midStr,
    'x-bili-aurora-eid': IdUtils.genAuroraEid(mid),
  };

  @override
  late final Map<String, String> grpcHeaders = GrpcHeaders.newHeaders(
    accessKey,
  );

  @override
  late final String csrf =
      cookieJar.domainCookies['bilibili.com']!['/']!['bili_jct']!.cookie.value;

  bool _hasDelete = false;

  String get storageKey => _midStr;

  @override
  Future<void> delete({
    AccountWriteBackOperation? admission,
    AccountWriteBackCoordinator? coordinator,
  }) {
    final writeBack = coordinator ?? accountWriteBackCoordinator;
    final owned = admission == null ? writeBack.tryAdmit() : null;
    if (admission == null && owned == null) {
      throw StateError('Account write-back is frozen');
    }
    _hasDelete = true;
    Accounts.revokeCredentials(this);
    return Future.wait([
      accountDeletionPort.deleteCookies(this),
      if (_box.isOpen && identical(_box.get(_midStr), this))
        accountDeletionPort.deleteLegacyAccount(_box, _midStr),
    ]).whenComplete(() => owned?.release());
  }

  @override
  Future<void>? onChange() {
    if (_hasDelete || !Accounts.ownsCredentials(this)) return null;
    return accountCookieMutationPort.persistLegacyAccount(this);
  }

  @override
  Map<String, dynamic>? toJson() => {
    'cookies': cookieJar.toJson(),
    'accessKey': accessKey,
    'refresh': refresh,
    'type': type.map((i) => i.index).toList(),
  };

  late final String _midStr = _restoredStorageKey ?? cookieJar
      .domainCookies['bilibili.com']!['/']!['DedeUserID']!
      .cookie
      .value;

  late final Box<LoginAccount> _box = Accounts.account;

  LoginAccount(
    this.cookieJar,
    this.accessKey,
    this.refresh, [
    Set<AccountType>? type,
  ]) : type = type ?? {},
       _restoredStorageKey = null,
       _restoredMid = null {
    cookieJar.setBuvid3();
  }

  /// Detached restore candidate. Explicit cached identity survives an empty
  /// jar; construction performs no buvid, Pref or protocol initialization.
  LoginAccount.restoreCaptured({
    required this.cookieJar,
    required String storageKey,
    required int mid,
    required this.accessKey,
    required this.refresh,
    required Set<AccountType> purposes,
    required this.activated,
  }) : type = Set.of(purposes),
       _restoredStorageKey = storageKey,
       _restoredMid = mid;

  factory LoginAccount.fromJson(Map json) => LoginAccount(
    BiliCookieJar.fromJson(json['cookies']),
    json['accessKey'],
    json['refresh'],
    (json['type'] as Iterable?)?.map((i) => AccountType.values[i]).toSet(),
  );

  @override
  int get hashCode => mid.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is LoginAccount && mid == other.mid);
}

class AnonymousAccount extends Account {
  @override
  final bool isLogin = false;
  @override
  DefaultCookieJar get cookieJar => _cookieJar;
  DefaultCookieJar _cookieJar = DefaultCookieJar()..setBuvid3();
  @override
  final String? accessKey = null;
  @override
  final String? refresh = null;
  @override
  final Set<AccountType> type = {};
  @override
  final int mid = 0;
  @override
  final String csrf = '';
  @override
  final Map<String, String> headers = Constants.baseHeaders;

  @override
  final Map<String, String> grpcHeaders = GrpcHeaders.newHeaders();

  @override
  bool activated = false;

  @override
  Future<void> delete({
    Object? recoveryOperation,
    AccountWriteBackOperation? admission,
    AccountWriteBackCoordinator? coordinator,
  }) async {
    final writeBack = coordinator ?? accountWriteBackCoordinator;
    final owned = admission == null ? writeBack.tryAdmit() : null;
    if (admission == null && owned == null) {
      throw StateError('Account write-back is frozen');
    }
    try {
      final reset = Accounts.beginAnonymousReset(this, recoveryOperation: recoveryOperation);
      activated = false;
      grpcHeaders['x-bili-fawkes-req-bin'] = GrpcHeaders.fawkes;
      await accountResetPersistencePort.clearAnonymousCookies(this);
      if (!Accounts.isCurrentAnonymousReset(reset)) return;
      cookieJar.setBuvid3();
      Accounts.completeAnonymousReset(this, reset);
    } finally {
      owned?.release();
    }
  }

  static final _instance = AnonymousAccount._();

  AnonymousAccount._();

  /// Only the Accounts empty-target restore boundary calls this after its
  /// successful write and epoch checks. Replacement retains ignoreExpires.
  void restoreCapturedState(
    Object operation,
    DefaultCookieJar jar,
    Set<AccountType> purposes,
    bool activated,
  ) {
    if (!Accounts.isCurrentCapturedRestore(operation)) {
      throw StateError('Anonymous restore requires the Accounts restore gate');
    }
    _cookieJar = jar;
    type
      ..clear()
      ..addAll(purposes);
    this.activated = activated;
  }

  factory AnonymousAccount() => _instance;

  @override
  int get hashCode => cookieJar.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AnonymousAccount && cookieJar == other.cookieJar);
}

extension BiliCookie on Cookie {
  void setBiliDomain([String domain = '.bilibili.com']) {
    this.domain = domain;
    httpOnly = false;
    path = '/';
  }
}

extension BiliCookieJar on DefaultCookieJar {
  Map<String, String> toJson() {
    final cookies = domainCookies['bilibili.com']?['/'] ?? const {};
    return {for (final i in cookies.values) i.cookie.name: i.cookie.value};
  }

  List<Cookie> toList() =>
      domainCookies['bilibili.com']?['/']?.entries
          .map((i) => i.value.cookie)
          .toList() ??
      [];

  void setBuvid3() {
    (domainCookies['bilibili.com'] ??= {
      '/': {},
    })['/']!['buvid3'] ??= SerializableCookie(
      Cookie('buvid3', IdUtils.genBuvid3())..setBiliDomain(),
    );
  }

  static DefaultCookieJar fromJson(Map json) =>
      DefaultCookieJar(ignoreExpires: true)
        ..domainCookies['bilibili.com'] = {
          '/': {
            for (final i in json.entries)
              i.key: SerializableCookie(
                Cookie(i.key, i.value)..setBiliDomain(),
              ),
          },
        };

  static DefaultCookieJar fromList(List cookies) =>
      DefaultCookieJar(ignoreExpires: true)
        ..domainCookies['bilibili.com'] = {
          '/': {
            for (final i in cookies)
              i['name']!: SerializableCookie(
                Cookie(i['name']!, i['value']!)..setBiliDomain(),
              ),
          },
        };
}

final class NoAccount extends Account {
  const NoAccount();
}
