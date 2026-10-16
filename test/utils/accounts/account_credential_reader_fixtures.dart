import 'package:PiliPlus/services/native_accounts/account_credential_reader.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_request_state.dart';

/// Delegates to the production reader and counts calls, proving the wired
/// request/lease path actually consumes the read-only adapter.
final class CountingCredentialReader implements AccountCredentialReader {
  CountingCredentialReader([this.inner = accountCredentialReader]);

  final AccountCredentialReader inner;
  int captures = 0;
  int csrfReads = 0;
  int accessKeyReads = 0;
  int refreshReads = 0;
  int boundCsrfReads = 0;
  int boundAccessKeyReads = 0;
  int boundRefreshReads = 0;

  @override
  AccountCredentialContext? captureRequest(
    Account owner,
    AccountRequestStamp<Account> stamp,
  ) {
    captures++;
    return inner.captureRequest(owner, stamp);
  }

  @override
  AccountBoundCredential<String> boundCsrfFor(
    Account owner,
    AccountRequestStamp<Account> stamp,
  ) {
    boundCsrfReads++;
    return inner.boundCsrfFor(owner, stamp);
  }

  @override
  AccountBoundCredential<String?> boundAccessKeyFor(
    Account owner,
    AccountRequestStamp<Account> stamp,
  ) {
    boundAccessKeyReads++;
    return inner.boundAccessKeyFor(owner, stamp);
  }

  @override
  AccountBoundCredential<String?> boundRefreshFor(
    Account owner,
    AccountRequestStamp<Account> stamp,
  ) {
    boundRefreshReads++;
    return inner.boundRefreshFor(owner, stamp);
  }

  @override
  String? csrfFor(Account owner, AccountRequestStamp<Account> stamp) {
    csrfReads++;
    return inner.csrfFor(owner, stamp);
  }

  @override
  String? accessKeyFor(Account owner, AccountRequestStamp<Account> stamp) {
    accessKeyReads++;
    return inner.accessKeyFor(owner, stamp);
  }

  @override
  String? refreshFor(Account owner, AccountRequestStamp<Account> stamp) {
    refreshReads++;
    return inner.refreshFor(owner, stamp);
  }

  @override
  List<AccountCredentialSummary> visibleAccounts() => inner.visibleAccounts();
}

/// Always unavailable: the caller must keep its existing revoked handling, and
/// no caller may turn a rejected stamp into a raw owner-field fallback.
final class DeniedCredentialReader implements AccountCredentialReader {
  const DeniedCredentialReader();

  @override
  AccountCredentialContext? captureRequest(
    Account owner,
    AccountRequestStamp<Account> stamp,
  ) => null;

  @override
  AccountBoundCredential<String> boundCsrfFor(
    Account owner,
    AccountRequestStamp<Account> stamp,
  ) =>
      const AccountBoundCredential.rejected();

  @override
  AccountBoundCredential<String?> boundAccessKeyFor(
    Account owner,
    AccountRequestStamp<Account> stamp,
  ) =>
      const AccountBoundCredential.rejected();

  @override
  AccountBoundCredential<String?> boundRefreshFor(
    Account owner,
    AccountRequestStamp<Account> stamp,
  ) =>
      const AccountBoundCredential.rejected();

  @override
  String? csrfFor(Account owner, AccountRequestStamp<Account> stamp) => null;

  @override
  String? accessKeyFor(Account owner, AccountRequestStamp<Account> stamp) =>
      null;

  @override
  String? refreshFor(Account owner, AccountRequestStamp<Account> stamp) => null;

  @override
  List<AccountCredentialSummary> visibleAccounts() => const [];
}
