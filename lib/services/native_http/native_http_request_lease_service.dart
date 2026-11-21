import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/effective_http_policy.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_accounts/account_cookie_mutation_port.dart';
import 'package:PiliPlus/services/native_accounts/account_credential_reader.dart';
import 'package:PiliPlus/services/native_accounts/account_write_back_coordinator.dart';
import 'package:PiliPlus/services/native_http/prepared_http_policy.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/accounts/account_manager/response_cookie_headers.dart';
import 'package:PiliPlus/utils/accounts/account_request_state.dart';
import 'package:dio/dio.dart';
import 'package:uuid/v4.dart';

typedef _RequestInput = ({Uri url, Map<String, String> headers, PreparedHTTPPolicy policy,
  Object? decoder, Object? encoder, Object validateStatus});

enum NativeHTTPRequestLeaseOutcome {
  finished,
  abandoned,
  expired,
  consumed,
  unknown,
  revoked,
  closed,
}

final class NativeHTTPRequestLeaseException implements Exception {
  const NativeHTTPRequestLeaseException(this.code);

  final String code;

  @override
  String toString() => 'Native HTTP request lease: $code';
}

/// Owned request data only; account and credential references stay in Dart.
final class NativeHTTPRequestLeaseSnapshot {
  NativeHTTPRequestLeaseSnapshot._({
    required this.requestID,
    required this.leaseID,
    required this.url,
    required Map<String, String> headers,
    required this.revision,
    required this.generation,
    required this.limit,
    required this.policy,
  }) : headers = Map.unmodifiable(headers);

  final String requestID;
  final String leaseID;
  final Uri url;
  final Map<String, String> headers;
  final int revision;
  final int generation;
  final int limit;
  final PreparedHTTPPolicy policy;
  String get method => 'GET';

  // Description alone does not establish Native transport compatibility.
  bool get executionAllowed => false;
}

final class NativeHTTPRequestRedirectHop {
  const NativeHTTPRequestRedirectHop({
    required this.statusCode,
    required this.location,
    required this.url,
  });

  final int statusCode;
  final String location;
  final Uri url;
}

final class NativeHTTPRequestLeaseResponse {
  NativeHTTPRequestLeaseResponse({
    required this.url,
    required this.statusCode,
    required this.cookieSource,
    Iterable<String> setCookieValues = const [],
    Iterable<NativeHTTPRequestRedirectHop> redirects = const [],
  }) : setCookieValues = List.unmodifiable(setCookieValues),
       redirects = List.unmodifiable(redirects);

  final Uri url;
  final int statusCode;
  final SetCookieSource cookieSource;
  final List<String> setCookieValues;
  final List<NativeHTTPRequestRedirectHop> redirects;
}

final class NativeHTTPRequestLeaseReceipt {
  const NativeHTTPRequestLeaseReceipt(
    this.outcome, {
    this.cookiesSaved = false,
    this.cookieCount = 0,
  });

  final NativeHTTPRequestLeaseOutcome outcome;
  final bool cookiesSaved;
  final int cookieCount;
}

/// Compatibility lease, not permission to execute a Native network request.
///
/// Completion seams run after the real CookieJar/Hive mutation. They must not
/// move that mutation past its ownership check or simulate another jar policy.
final class NativeHTTPRequestLeaseService {
  NativeHTTPRequestLeaseService({
    BaseOptions Function()? options,
    EffectiveHTTPPolicySnapshot Function()? policy,
    Account Function()? recommendAccount,
    Future<List<Cookie>> Function(Account, Uri)? loadCookies,
    Future<void> Function(Account, Uri, Future<void>)? awaitCookieSave,
    Future<void> Function(Account, Future<void>?)? awaitAccountPersistence,
    Duration Function()? now,
    AccountWriteBackCoordinator? writeBackCoordinator,
    AccountCredentialReader? credentialReader,
    this.ttl = const Duration(minutes: 1),
    this.maxLiveLeases = 32,
    this.maxTombstones = 128,
    this.autoExpire = true,
  }) : writeBackCoordinator =
            writeBackCoordinator ?? accountWriteBackCoordinator,
       credentialReader = credentialReader ?? accountCredentialReader,
       _options = options ?? (() => Request.dio.options),
       // Custom options without a paired describer must never borrow the
       // production pool's known policy (existing fixture/compatibility seam).
       _policy = policy ?? (options == null ? (() => Request.effectiveHTTPPolicy) : (() => null)),
       _recommendAccount = recommendAccount ?? (() => Accounts.get(AccountType.recommend)),
       _loadCookies = loadCookies ?? ((account, uri) => account.cookieJar.loadForRequest(uri)),
       _awaitCookieSave = awaitCookieSave ?? ((account, uri, saving) => saving),
       _awaitAccountPersistence = awaitAccountPersistence ?? ((account, saving) async { await saving; }),
       _injectedNow = now {
    if (ttl <= Duration.zero || maxLiveLeases < 1 || maxTombstones < 1) {
      throw ArgumentError('Lease lifetime and capacities must be positive');
    }
  }

  final Duration ttl;
  final int maxLiveLeases;
  final int maxTombstones;
  /// Shared admission/drain gate for the response write-back; composition only.
  final AccountWriteBackCoordinator writeBackCoordinator;

  /// Read-only credential context provider for prepared request headers.
  final AccountCredentialReader credentialReader;
  final BaseOptions Function() _options;
  final EffectiveHTTPPolicySnapshot? Function() _policy;
  final Account Function() _recommendAccount;
  final Future<List<Cookie>> Function(Account, Uri) _loadCookies;
  final Future<void> Function(Account, Uri, Future<void>) _awaitCookieSave;
  final Future<void> Function(Account, Future<void>?) _awaitAccountPersistence;
  final Duration Function()? _injectedNow;
  final bool autoExpire;
  final Stopwatch _clock = Stopwatch()..start();
  final _live = <String, _LiveLease>{};
  final _terminal = <String, _TerminalLease>{};
  Timer? _expiryTimer;
  bool _closed = false;

  int get liveLeaseCount => _live.length;
  int get pendingLeaseCount => _live.values.where((entry) => !entry.finishing && entry.context == null).length;
  int get finishingLeaseCount => _live.values.where((entry) => entry.finishing).length;
  int get tombstoneCount => _terminal.length;
  Duration get _now => _injectedNow?.call() ?? _clock.elapsed;

  static final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  static bool isValidID(String value) => value.length == 36 && _uuid.hasMatch(value);

  Future<NativeHTTPRequestLeaseSnapshot> prepare({
    required String requestID,
    int limit = 10,
  }) async {
    final key = _id(requestID);
    _ensureOpen();
    pruneExpired();
    if (_live.containsKey(key) || _terminal.containsKey(key)) {
      throw const NativeHTTPRequestLeaseException('consumed');
    }
    if (limit < 1 || limit > 30) {
      throw const NativeHTTPRequestLeaseException('invalidRequest');
    }
    if (_live.length >= maxLiveLeases) {
      throw const NativeHTTPRequestLeaseException('capacity');
    }
    // Register before the first await; abandon does not need the returned ID.
    final entry = _LiveLease(const UuidV4().generate(), _now + ttl);
    _live[key] = entry;
    _startExpiryTimer();
    try {
      final account = _recommendAccount();
      if (account is NoAccount) {
        throw const NativeHTTPRequestLeaseException('noAccount');
      }
      // Anonymous capture can install its generation and change revision.
      final stamp = Accounts.captureRequest(account);
      if (stamp == null) {
        throw const NativeHTTPRequestLeaseException('revoked');
      }
      final revision = Accounts.requestRevision;
      final input = _captureInput(account, limit, stamp);
      final url = input.url;
      final cookies = await _loadCookies(account, url);
      _ensurePreparing(key, entry);
      if (!identical(_recommendAccount(), account) ||
          Accounts.requestRevision != revision ||
          !Accounts.isCurrentRequest(stamp)) {
        throw const NativeHTTPRequestLeaseException('snapshotChanged');
      }
      _confirmInput(account, limit, stamp, input);
      final snapshot = NativeHTTPRequestLeaseSnapshot._(
        requestID: key, leaseID: entry.leaseID, url: url, headers: _withCookies(input.headers, cookies),
        revision: revision, generation: stamp.generation, limit: limit,
        policy: input.policy,
      );
      entry.context = _PreparedLease(snapshot, stamp, input);
      return snapshot;
    } catch (error) {
      if (identical(_live[key], entry)) {
        _live.remove(key);
        _rememberTerminal(key, entry.leaseID, NativeHTTPRequestLeaseOutcome.consumed);
      }
      if (error is NativeHTTPRequestLeaseException) rethrow;
      throw const NativeHTTPRequestLeaseException('invalidRequest');
    }
  }

  _RequestInput _captureInput(
    Account account, int limit, AccountRequestStamp<Account> stamp,
  ) {
    final effective = _policy();
    // Describe the legacy SearchHttp request. Transport support is decided
    // before sending; a candidate's restrictions never rewrite this policy.
    final composed = Options(method: 'GET').compose(
      _options(), Api.searchTrending, queryParameters: {'limit': limit},
    );
    final url = Uri.https('api.bilibili.com', Api.searchTrending, {'limit': '$limit'});
    if (composed.uri.toString() != url.toString()) {
      throw const NativeHTTPRequestLeaseException('invalidRequest');
    }
    // Read-only credential context for the already-bound owner/generation.
    // A null result keeps the existing revoked path; owner checks above still
    // govern the prepared snapshot.
    final credentials = credentialReader.captureRequest(account, stamp);
    if (credentials == null) {
      throw const NativeHTTPRequestLeaseException('revoked');
    }
    final headers = _headers(composed.headers)
      ..addAll(_headers(credentials.headers))
      ..['referer'] ??= HttpString.baseUrl;
    return (url: url, headers: headers, decoder: composed.responseDecoder,
      encoder: composed.requestEncoder, validateStatus: composed.validateStatus,
      policy: PreparedHTTPPolicy.capture(effective: effective, request: composed, headers: headers));
  }

  void _confirmInput(Account account, int limit, AccountRequestStamp<Account> stamp, _RequestInput input) {
    // Pool generations cannot detect direct BaseOptions/retry/header edits.
    const changed = NativeHTTPRequestLeaseException('snapshotChanged');
    try {
      final current = _captureInput(account, limit, stamp);
      if (!input.policy.sameAs(current.policy) || current.url != input.url ||
          !identical(input.decoder, current.decoder) ||
          !identical(input.encoder, current.encoder) ||
          !identical(input.validateStatus, current.validateStatus) ||
          input.headers.length != current.headers.length ||
          !input.headers.entries.every((entry) => current.headers[entry.key] == entry.value)) {
        throw changed;
      }
    } catch (_) {
      throw changed;
    }
  }

  static Map<String, String> _withCookies(Map<String, String> headers, List<Cookie> cookies) => {
    ...headers,
    HttpHeaders.cookieHeader: AccountManager.getCookies([
      ...?headers[HttpHeaders.cookieHeader]?.split(';').where((value) => value.isNotEmpty).map(Cookie.fromSetCookieValue),
      ...cookies,
    ]),
  };

  Future<Map<String, String>> prepareRetry({
    required String requestID,
    required String leaseID,
    required int attempt,
  }) async {
    final key = _id(requestID);
    final token = _id(leaseID);
    _ensureOpen();
    pruneExpired();
    final entry = _live[key];
    if (entry == null) throw NativeHTTPRequestLeaseException(_terminalReceipt(key, token: token).outcome.name);
    if (entry.leaseID != token) throw const NativeHTTPRequestLeaseException('leaseMismatch');
    if (entry.finishing) throw const NativeHTTPRequestLeaseException('consumed');
    final context = entry.context;
    if (context == null) throw const NativeHTTPRequestLeaseException('notPrepared');
    if (context.preparingRetry) throw const NativeHTTPRequestLeaseException('retryInProgress');
    final snapshot = context.snapshot;
    if (attempt != context.retryAttempt + 1 || attempt > snapshot.policy.retryLimit) {
      throw const NativeHTTPRequestLeaseException('invalidRetryAttempt');
    }
    final account = context.stamp.account;
    context.preparingRetry = true;
    try {
      if (!_owns(context)) throw const NativeHTTPRequestLeaseException('revoked');
      _confirmInput(account, snapshot.limit, context.stamp, context.input);
      final cookies = await _loadCookies(account, snapshot.url);
      _ensurePreparing(key, entry);
      if (!_owns(context)) throw const NativeHTTPRequestLeaseException('revoked');
      _confirmInput(account, snapshot.limit, context.stamp, context.input);
      // Dio reuses RequestOptions. Its account interceptor merges the previous
      // Cookie header with a fresh jar read from the originally bound owner.
      final headers = Map<String, String>.unmodifiable(_withCookies(context.lastHeaders, cookies));
      context
        ..lastHeaders = headers
        ..retryAttempt = attempt;
      return headers;
    } on NativeHTTPRequestLeaseException {
      rethrow;
    } catch (_) {
      throw const NativeHTTPRequestLeaseException('invalidRequest');
    } finally {
      context.preparingRetry = false;
    }
  }

  Future<NativeHTTPRequestLeaseReceipt> finish({
    required String requestID,
    required String leaseID,
    required NativeHTTPRequestLeaseResponse response,
  }) async {
    final key = _id(requestID);
    final token = _id(leaseID);
    if (_closed) return const NativeHTTPRequestLeaseReceipt(NativeHTTPRequestLeaseOutcome.closed);
    pruneExpired();
    final entry = _live[key];
    if (entry == null) return _terminalReceipt(key, token: token);
    if (entry.leaseID != token) throw const NativeHTTPRequestLeaseException('leaseMismatch');
    if (entry.finishing) return const NativeHTTPRequestLeaseReceipt(NativeHTTPRequestLeaseOutcome.consumed);
    final context = entry.context;
    if (context == null) throw const NativeHTTPRequestLeaseException('notPrepared');
    // Keep a closed marker through awaits and expiry, without account references.
    entry
      ..finishing = true
      ..context = null;
    var outcome = NativeHTTPRequestLeaseOutcome.consumed;
    try {
      final cookieUrl = _cookieUrl(context.snapshot, response);
      if (!_owns(context)) {
        outcome = _closed ? NativeHTTPRequestLeaseOutcome.closed : NativeHTTPRequestLeaseOutcome.revoked;
        return NativeHTTPRequestLeaseReceipt(outcome);
      }
      final ParsedSetCookieHeaders parsed;
      try {
        parsed = parseResponseCookieHeaders(response.setCookieValues, source: response.cookieSource);
      } catch (_) {
        throw const NativeHTTPRequestLeaseException('invalidCookieHeaders');
      }
      if (!parsed.nativePersistenceSupported) {
        throw const NativeHTTPRequestLeaseException('unsupportedCookieRepresentation');
      }
      final cookies = parsed.cookiesForNativePersistence;
      if (cookies.isEmpty) {
        outcome = NativeHTTPRequestLeaseOutcome.finished;
        return NativeHTTPRequestLeaseReceipt(outcome);
      }
      if (!_owns(context)) {
        outcome = _closed ? NativeHTTPRequestLeaseOutcome.closed : NativeHTTPRequestLeaseOutcome.revoked;
        return NativeHTTPRequestLeaseReceipt(outcome);
      }
      final account = context.stamp.account;
      // Frozen transitions reject new write-back admission without touching the
      // jar; the existing outcome vocabulary is unchanged (no write applied).
      final admission = writeBackCoordinator.tryAdmit();
      if (admission == null) {
        outcome = NativeHTTPRequestLeaseOutcome.revoked;
        return NativeHTTPRequestLeaseReceipt(outcome);
      }
      try {
        // Pinned CookieJar mutates before this Future completes. Do not defer it.
        final saving = accountCookieMutationPort.saveResponseCookies(account, cookieUrl, cookies);
        Accounts.notifyCookieMutation(account);
        await _awaitCookieSave(account, cookieUrl, saving);
        if (!_owns(context)) {
          outcome = _closed ? NativeHTTPRequestLeaseOutcome.closed : NativeHTTPRequestLeaseOutcome.revoked;
          return NativeHTTPRequestLeaseReceipt(outcome, cookiesSaved: true, cookieCount: cookies.length);
        }
        final persisting = account.onChange();
        await _awaitAccountPersistence(account, persisting);
        outcome = _owns(context) ? NativeHTTPRequestLeaseOutcome.finished
            : _closed ? NativeHTTPRequestLeaseOutcome.closed : NativeHTTPRequestLeaseOutcome.revoked;
        return NativeHTTPRequestLeaseReceipt(outcome, cookiesSaved: true, cookieCount: cookies.length);
      } finally {
        // Exactly once, including throw/abandon/dispose paths; the outer
        // finally still owns lease-table cleanup.
        admission.release();
      }
    } catch (error) {
      if (error is NativeHTTPRequestLeaseException) rethrow;
      throw const NativeHTTPRequestLeaseException('persistenceFailed');
    } finally {
      if (identical(_live[key], entry)) {
        _live.remove(key);
        _rememberTerminal(key, entry.leaseID, outcome);
      }
    }
  }

  static Uri _cookieUrl(NativeHTTPRequestLeaseSnapshot snapshot, NativeHTTPRequestLeaseResponse response) {
    const invalid = NativeHTTPRequestLeaseException('invalidResponse');
    final original = snapshot.url;
    final status = response.statusCode;
    if (status < 100 || status > 599) throw invalid;
    final redirects = response.redirects;
    if (redirects.isEmpty) {
      if (response.url.toString() != original.toString()) throw invalid;
      return original;
    }
    final limit = snapshot.policy.redirectLimit;
    // A terminal 3xx may require additional Location-scoped writes in Dio.
    if (limit == null || redirects.length > limit ||
        response.cookieSource != SetCookieSource.separatedFields ||
        status < 200 || (status >= 300 && status < 400)) {
      throw invalid;
    }
    bool inOrigin(Uri url) => url.scheme == original.scheme && url.host == original.host &&
        url.port == original.port && url.userInfo.isEmpty && !url.hasFragment;

    var current = original;
    final visited = <Uri>{};
    try {
      for (final hop in redirects) {
        if (!const {301, 302, 303, 307, 308}.contains(hop.statusCode) || hop.location.isEmpty) {
          throw invalid;
        }
        final next = current.resolve(hop.location);
        if (!inOrigin(next) || next != hop.url || !visited.add(next)) throw invalid;
        current = next;
      }
      if (current != response.url) throw invalid;
      // Dio's realUri is the last Location reference. AccountManager resolves
      // that reference against the original request when it persists Cookies.
      final cookieUrl = original.resolve(redirects.last.location);
      if (!inOrigin(cookieUrl)) throw invalid;
      return cookieUrl;
    } on FormatException {
      throw invalid;
    }
  }

  NativeHTTPRequestLeaseReceipt abandon({required String requestID, String? leaseID}) {
    final key = _id(requestID);
    final token = leaseID == null ? null : _id(leaseID);
    if (_closed) return const NativeHTTPRequestLeaseReceipt(NativeHTTPRequestLeaseOutcome.closed);
    pruneExpired();
    final entry = _live[key];
    if (entry == null) {
      if (_terminal.containsKey(key)) return _terminalReceipt(key, token: token);
      // Cover a cleanup command that arrives before its prepare command.
      _rememberTerminal(key, token, NativeHTTPRequestLeaseOutcome.abandoned);
      return const NativeHTTPRequestLeaseReceipt(NativeHTTPRequestLeaseOutcome.unknown);
    }
    if (token != null && entry.leaseID != token) throw const NativeHTTPRequestLeaseException('leaseMismatch');
    if (entry.finishing) return const NativeHTTPRequestLeaseReceipt(NativeHTTPRequestLeaseOutcome.consumed);
    _live.remove(key);
    _rememberTerminal(key, entry.leaseID, NativeHTTPRequestLeaseOutcome.abandoned);
    return const NativeHTTPRequestLeaseReceipt(NativeHTTPRequestLeaseOutcome.abandoned);
  }

  void pruneExpired() {
    if (_closed) return;
    final at = _now;
    _terminal.removeWhere((key, entry) => at >= entry.expiresAt);
    for (final key in _live.keys.toList()) {
      final entry = _live[key]!;
      if (!entry.finishing && at >= entry.expiresAt) {
        _live.remove(key);
        _rememberTerminal(key, entry.leaseID, NativeHTTPRequestLeaseOutcome.expired);
      }
    }
    _stopExpiryTimerIfIdle();
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _live.clear();
    _terminal.clear();
    _clock.stop();
  }

  bool _owns(_PreparedLease context) => !_closed && Accounts.isCurrentRequest(context.stamp);

  void _ensureOpen() {
    if (_closed) throw const NativeHTTPRequestLeaseException('closed');
  }

  void _ensurePreparing(String key, _LiveLease entry) {
    _ensureOpen();
    pruneExpired();
    if (!identical(_live[key], entry) || entry.finishing) {
      throw NativeHTTPRequestLeaseException(_terminal[key]?.outcome.name ?? 'consumed');
    }
  }

  void _rememberTerminal(String key, String? leaseID, NativeHTTPRequestLeaseOutcome outcome) {
    if (_closed) return;
    _terminal[key] = _TerminalLease(leaseID, outcome, _now + ttl);
    while (_terminal.length > maxTombstones) {
      _terminal.remove(_terminal.keys.first);
    }
    _startExpiryTimer();
  }

  void _startExpiryTimer() {
    if (!autoExpire || _closed || _expiryTimer != null) return;
    final interval = Duration(microseconds: (ttl.inMicroseconds ~/ 2).clamp(1, 10000000).toInt());
    _expiryTimer = Timer.periodic(interval, (_) => pruneExpired());
  }

  void _stopExpiryTimerIfIdle() {
    if (_live.isEmpty && _terminal.isEmpty) {
      _expiryTimer?.cancel();
      _expiryTimer = null;
    }
  }

  NativeHTTPRequestLeaseReceipt _terminalReceipt(String key, {String? token}) {
    final entry = _terminal[key];
    if (entry == null) {
      return const NativeHTTPRequestLeaseReceipt(NativeHTTPRequestLeaseOutcome.unknown);
    }
    if (token != null && entry.leaseID != null && entry.leaseID != token) {
      throw const NativeHTTPRequestLeaseException('leaseMismatch');
    }
    return NativeHTTPRequestLeaseReceipt(
      entry.outcome == NativeHTTPRequestLeaseOutcome.expired
          ? NativeHTTPRequestLeaseOutcome.expired : NativeHTTPRequestLeaseOutcome.consumed,
    );
  }

  static String _id(String value) {
    if (!isValidID(value)) throw const NativeHTTPRequestLeaseException('invalidRequest');
    return value.toLowerCase();
  }

  static Map<String, String> _headers(Map<String, dynamic> input) {
    final output = <String, String>{};
    for (final entry in input.entries) {
      final name = entry.key.toLowerCase();
      final value = entry.value;
      if (name.isEmpty || !name.codeUnits.every(_isHeaderToken) ||
          value is! String || value.contains('\r') || value.contains('\n') ||
          name == 'host' || name == 'content-length' || output.containsKey(name)) {
        throw const NativeHTTPRequestLeaseException('invalidRequest');
      }
      output[name] = value;
    }
    return output;
  }

  static bool _isHeaderToken(int code) =>
      (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122) ||
      "!#\$%&'*+-.^_`|~".contains(String.fromCharCode(code));
}

final class _LiveLease {
  _LiveLease(this.leaseID, this.expiresAt);
  final String leaseID;
  final Duration expiresAt;
  _PreparedLease? context;
  bool finishing = false;
}

final class _PreparedLease {
  _PreparedLease(this.snapshot, this.stamp, this.input) : lastHeaders = snapshot.headers;
  final NativeHTTPRequestLeaseSnapshot snapshot;
  final AccountRequestStamp<Account> stamp;
  final _RequestInput input;
  Map<String, String> lastHeaders;
  int retryAttempt = 0;
  bool preparingRetry = false;
}

final class _TerminalLease {
  const _TerminalLease(this.leaseID, this.outcome, this.expiresAt);
  final String? leaseID;
  final NativeHTTPRequestLeaseOutcome outcome;
  final Duration expiresAt;
}
