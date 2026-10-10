import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_request_state.dart';

/// Immutable read-only credential snapshot for one bound request owner.
///
/// This is not an authority or an authorization token: callers keep their
/// existing owner/stamp/generation checks, and the snapshot holds no Account,
/// jar, Cookie or Hive reference.
final class AccountCredentialContext {
  AccountCredentialContext._({
    required this.mid,
    required this.isLogin,
    required this.activated,
    required this.generation,
    required this.accessKey,
    required Map<String, String> headers,
    required Map<String, String> grpcHeaders,
  })  : headers = Map.unmodifiable(headers),
        grpcHeaders = Map.unmodifiable(grpcHeaders);

  final int mid;
  final bool isLogin;
  final bool activated;

  /// Runtime request generation from the bound stamp; not a durable identity.
  final int generation;
  final String? accessKey;
  final Map<String, String> headers;
  final Map<String, String> grpcHeaders;
}

/// Read-only page/display summary; never a live Account or credential map.
final class AccountCredentialSummary {
  const AccountCredentialSummary({
    required this.storageKey,
    required this.mid,
    required this.isLogin,
    required this.activated,
  });

  final String storageKey;
  final int mid;
  final bool isLogin;
  final bool activated;
}

/// Read-only credential adapter. It never installs, activates, revokes, writes
/// a jar/Hive box or performs network I/O. A null result means the bound
/// owner/stamp is no longer installed and the caller must keep its existing
/// revoked-handling path.
abstract interface class AccountCredentialReader {
  AccountCredentialContext? captureRequest(
    Account owner,
    AccountRequestStamp<Account> stamp,
  );

  String? csrfFor(Account owner, AccountRequestStamp<Account> stamp);

  String? accessKeyFor(Account owner, AccountRequestStamp<Account> stamp);

  List<AccountCredentialSummary> visibleAccounts();
}

const AccountCredentialReader accountCredentialReader =
    DartAccountCredentialReader();

final class DartAccountCredentialReader implements AccountCredentialReader {
  const DartAccountCredentialReader();

  @override
  AccountCredentialContext? captureRequest(
    Account owner,
    AccountRequestStamp<Account> stamp,
  ) {
    if (!_isBound(owner, stamp)) return null;
    return AccountCredentialContext._(
      mid: owner.mid,
      isLogin: owner.isLogin,
      activated: owner.activated,
      generation: stamp.generation,
      accessKey: owner.accessKey,
      headers: owner.headers,
      grpcHeaders: owner.grpcHeaders,
    );
  }

  @override
  String? csrfFor(Account owner, AccountRequestStamp<Account> stamp) {
    if (!_isBound(owner, stamp)) return null;
    return owner.csrf;
  }

  @override
  String? accessKeyFor(Account owner, AccountRequestStamp<Account> stamp) {
    if (!_isBound(owner, stamp)) return null;
    return owner.accessKey;
  }

  @override
  List<AccountCredentialSummary> visibleAccounts() {
    final box = Accounts.account;
    return List.unmodifiable([
      for (final entry in box.toMap().entries)
        if (entry.key is String)
          AccountCredentialSummary(
            storageKey: entry.key as String,
            mid: entry.value.mid,
            isLogin: entry.value.isLogin,
            activated: entry.value.activated,
          ),
    ]);
  }

  /// Tracker identity first, so a non-current stamp never reaches
  /// `ownsCredentials` and cannot activate a dormant anonymous singleton.
  bool _isBound(Account owner, AccountRequestStamp<Account> stamp) =>
      identical(stamp.account, owner) &&
      Accounts.isCurrentRequest(stamp);
}
