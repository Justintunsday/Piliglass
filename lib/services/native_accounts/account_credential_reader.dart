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

/// Three-way binding of one credential read.
///
/// [notInstalled] means the owner has no captured stamp at all (never installed
/// or uninstalled): only this explicit legacy case may fall back to a historical
/// direct field. [rejected] means a stamp exists but the reader no longer
/// accepts it (revoked, retired, restore/recovery window, closed storage or a
/// foreign stamp): callers must fail closed and must never convert this into a
/// raw owner-field read. [bound] carries the real value, and a null [value] of
/// a bound nullable credential (for example a missing access key) is legitimate
/// data, not a rejection.
enum AccountCredentialBinding { notInstalled, rejected, bound }

/// Tagged result of one bound credential read.
final class AccountBoundCredential<T> {
  const AccountBoundCredential._(this.binding, this.value);

  const AccountBoundCredential.notInstalled()
      : this._(AccountCredentialBinding.notInstalled, null);

  const AccountBoundCredential.rejected()
      : this._(AccountCredentialBinding.rejected, null);

  const AccountBoundCredential.bound(T value)
      : this._(AccountCredentialBinding.bound, value);

  final AccountCredentialBinding binding;
  final T? value;

  bool get isNotInstalled => binding == AccountCredentialBinding.notInstalled;
  bool get isRejected => binding == AccountCredentialBinding.rejected;
  bool get isBound => binding == AccountCredentialBinding.bound;
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

  /// Tagged csrf read for an already captured stamp. A stamp the reader no
  /// longer accepts returns [AccountCredentialBinding.rejected] and must never
  /// be replaced by a raw owner field. A bound owner returns the real jar value
  /// with the historical throw semantics when the jar entry is absent.
  AccountBoundCredential<String> boundCsrfFor(
    Account owner,
    AccountRequestStamp<Account> stamp,
  );

  /// Tagged access-key read. A bound value may be null: a nullable credential
  /// that is legitimately absent is bound data, not a rejection.
  AccountBoundCredential<String?> boundAccessKeyFor(
    Account owner,
    AccountRequestStamp<Account> stamp,
  );

  /// Tagged refresh-token read. A bound value may be null: a nullable token
  /// that is legitimately absent is bound data, not a rejection.
  AccountBoundCredential<String?> boundRefreshFor(
    Account owner,
    AccountRequestStamp<Account> stamp,
  );

  /// Legacy nullable wrapper: null when the reader rejects the stamp. csrf is
  /// non-null whenever bound, so null here is always a rejection.
  String? csrfFor(Account owner, AccountRequestStamp<Account> stamp);

  /// Legacy nullable wrapper: null when the reader rejects the stamp or when
  /// the bound access key is legitimately absent. It cannot distinguish the
  /// two; use [boundAccessKeyFor] when the distinction matters.
  String? accessKeyFor(Account owner, AccountRequestStamp<Account> stamp);

  /// Legacy nullable wrapper: null when the reader rejects the stamp or when
  /// the bound refresh token is legitimately absent. It cannot distinguish the
  /// two; use [boundRefreshFor] when the distinction matters.
  String? refreshFor(Account owner, AccountRequestStamp<Account> stamp);

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
  AccountBoundCredential<String> boundCsrfFor(
    Account owner,
    AccountRequestStamp<Account> stamp,
  ) {
    if (!_isBound(owner, stamp)) return const AccountBoundCredential.rejected();
    // Bound contexts keep the historical getter semantics: a missing jar entry
    // throws exactly like the direct field, it never becomes a rejection.
    return AccountBoundCredential.bound(owner.csrf);
  }

  @override
  AccountBoundCredential<String?> boundAccessKeyFor(
    Account owner,
    AccountRequestStamp<Account> stamp,
  ) {
    if (!_isBound(owner, stamp)) return const AccountBoundCredential.rejected();
    return AccountBoundCredential.bound(owner.accessKey);
  }

  @override
  AccountBoundCredential<String?> boundRefreshFor(
    Account owner,
    AccountRequestStamp<Account> stamp,
  ) {
    if (!_isBound(owner, stamp)) return const AccountBoundCredential.rejected();
    return AccountBoundCredential.bound(owner.refresh);
  }

  @override
  String? csrfFor(Account owner, AccountRequestStamp<Account> stamp) {
    final bound = boundCsrfFor(owner, stamp);
    return bound.isBound ? bound.value : null;
  }

  @override
  String? accessKeyFor(Account owner, AccountRequestStamp<Account> stamp) {
    final bound = boundAccessKeyFor(owner, stamp);
    return bound.isBound ? bound.value : null;
  }

  @override
  String? refreshFor(Account owner, AccountRequestStamp<Account> stamp) {
    final bound = boundRefreshFor(owner, stamp);
    return bound.isBound ? bound.value : null;
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
