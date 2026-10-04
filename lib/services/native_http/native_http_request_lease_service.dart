import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/effective_http_policy.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/native_http/prepared_http_policy.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/accounts/account_manager/response_cookie_headers.dart';
import 'package:PiliPlus/utils/accounts/account_request_state.dart';
import 'package:dio/dio.dart';
import 'package:uuid/v4.dart';

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

final class NativeHTTPRequestLeaseResponse {
  NativeHTTPRequestLeaseResponse({
    required this.url,
    required this.statusCode,
    required this.cookieSource,
    Iterable<String> setCookieValues = const [],
  }) : setCookieValues = List.unmodifiable(setCookieValues);

  final Uri url;
  final int statusCode;
  final SetCookieSource cookieSource;
  final List<String> setCookieValues;
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
    this.ttl = const Duration(minutes: 1),
    this.maxLiveLeases = 32,
    this.maxTombstones = 128,
    this.autoExpire = true,
  }) : _options = options ?? (() => Request.dio.options),
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
      final input = _captureInput(account, limit);
      final url = input.url;
      final headers = input.headers;
      final cookies = await _loadCookies(account, url);
      _ensurePreparing(key, entry);
      if (!identical(_recommendAccount(), account) ||
          Accounts.requestRevision != revision ||
          !Accounts.isCurrentRequest(stamp)) {
        throw const NativeHTTPRequestLeaseException('snapshotChanged');
      }
      // Pool generations cannot detect direct BaseOptions/retry/header edits.
      // Recompose all effective inputs before adding the awaited Cookie values.
      try {
        final current = _captureInput(account, limit);
        if (!input.policy.sameAs(current.policy) || current.url != url ||
            !identical(input.decoder, current.decoder) ||
            !identical(input.encoder, current.encoder) ||
            !identical(input.validateStatus, current.validateStatus) ||
            headers.length != current.headers.length ||
            !headers.entries.every((entry) => current.headers[entry.key] == entry.value)) {
          throw const NativeHTTPRequestLeaseException('snapshotChanged');
        }
      } catch (_) {
        throw const NativeHTTPRequestLeaseException('snapshotChanged');
      }
      final previousCookies = headers[HttpHeaders.cookieHeader];
      headers[HttpHeaders.cookieHeader] = AccountManager.getCookies([
        ...?previousCookies?.split(';').where((value) => value.isNotEmpty).map(Cookie.fromSetCookieValue),
        ...cookies,
      ]);
      final snapshot = NativeHTTPRequestLeaseSnapshot._(
        requestID: key, leaseID: entry.leaseID, url: url, headers: headers,
        revision: revision, generation: stamp.generation, limit: limit,
        policy: input.policy,
      );
      entry.context = _PreparedLease(snapshot, stamp);
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

  ({Uri url, Map<String, String> headers, PreparedHTTPPolicy policy,
    Object? decoder, Object? encoder, Object validateStatus}) _captureInput(
    Account account, int limit,
  ) {
    final effective = _policy();
    final composed = Options(method: 'GET', followRedirects: false).compose(
      _options(), Api.searchTrending, queryParameters: {'limit': limit},
    );
    final url = Uri.https('api.bilibili.com', Api.searchTrending, {'limit': '$limit'});
    if (composed.uri.toString() != url.toString()) {
      throw const NativeHTTPRequestLeaseException('invalidRequest');
    }
    final headers = _headers(composed.headers)
      ..addAll(_headers(account.headers))
      ..['referer'] ??= HttpString.baseUrl;
    return (url: url, headers: headers, decoder: composed.responseDecoder,
      encoder: composed.requestEncoder, validateStatus: composed.validateStatus,
      policy: PreparedHTTPPolicy.capture(effective: effective, request: composed, headers: headers));
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
      if (response.url.toString() != context.snapshot.url.toString() ||
          response.statusCode < 100 || response.statusCode > 599) {
        throw const NativeHTTPRequestLeaseException('invalidResponse');
      }
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
      // Pinned CookieJar mutates before this Future completes. Do not defer it.
      final saving = account.cookieJar.saveFromResponse(context.snapshot.url, cookies);
      Accounts.notifyCookieMutation(account);
      await _awaitCookieSave(account, context.snapshot.url, saving);
      if (!_owns(context)) {
        outcome = _closed ? NativeHTTPRequestLeaseOutcome.closed : NativeHTTPRequestLeaseOutcome.revoked;
        return NativeHTTPRequestLeaseReceipt(outcome, cookiesSaved: true, cookieCount: cookies.length);
      }
      final persisting = account.onChange();
      await _awaitAccountPersistence(account, persisting);
      outcome = _owns(context) ? NativeHTTPRequestLeaseOutcome.finished
          : _closed ? NativeHTTPRequestLeaseOutcome.closed : NativeHTTPRequestLeaseOutcome.revoked;
      return NativeHTTPRequestLeaseReceipt(outcome, cookiesSaved: true, cookieCount: cookies.length);
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
  const _PreparedLease(this.snapshot, this.stamp);
  final NativeHTTPRequestLeaseSnapshot snapshot;
  final AccountRequestStamp<Account> stamp;
}

final class _TerminalLease {
  const _TerminalLease(this.leaseID, this.outcome, this.expiresAt);
  final String? leaseID;
  final NativeHTTPRequestLeaseOutcome outcome;
  final Duration expiresAt;
}
