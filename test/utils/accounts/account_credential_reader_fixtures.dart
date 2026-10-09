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

  @override
  AccountCredentialContext? captureRequest(
    Account owner,
    AccountRequestStamp<Account> stamp,
  ) {
    captures++;
    return inner.captureRequest(owner, stamp);
  }

  @override
  String? csrfFor(Account owner, AccountRequestStamp<Account> stamp) {
    csrfReads++;
    return inner.csrfFor(owner, stamp);
  }

  @override
  List<AccountCredentialSummary> visibleAccounts() => inner.visibleAccounts();
}

/// Always unavailable: the caller must keep its existing revoked handling.
final class DeniedCredentialReader implements AccountCredentialReader {
  const DeniedCredentialReader();

  @override
  AccountCredentialContext? captureRequest(
    Account owner,
    AccountRequestStamp<Account> stamp,
  ) => null;

  @override
  String? csrfFor(Account owner, AccountRequestStamp<Account> stamp) => null;

  @override
  List<AccountCredentialSummary> visibleAccounts() => const [];
}
