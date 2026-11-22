import 'package:PiliPlus/services/native_http/native_http_request_lease_service.dart';
import 'package:PiliPlus/utils/accounts/account_manager/response_cookie_headers.dart';

/// Strict command codec; lifecycle and persistence belong to the lease service.
final class NativeHTTPRequestLeaseBridge {
  NativeHTTPRequestLeaseBridge({NativeHTTPRequestLeaseService? service})
    : service = service ?? NativeHTTPRequestLeaseService();

  final NativeHTTPRequestLeaseService service;

  Future<Map<String, Object?>> handle(String method, Object? arguments) async {
    try {
      final values = _map(arguments);
      final requestID = _id(values['requestID']);
      switch (method) {
        case 'prepareNativeHTTPRequest':
          _keys(values, {'requestID', 'purpose', 'limit'});
          final limit = values['limit'];
          if (values['purpose'] != 'searchTrending' || limit is! int || limit < 1 || limit > 30) {
            throw const NativeHTTPRequestLeaseException('invalidArguments');
          }
          final snapshot = await service.prepare(requestID: requestID, limit: limit);
          return Map.unmodifiable({
            'state': 'prepared', 'requestID': snapshot.requestID, 'leaseID': snapshot.leaseID,
            'url': snapshot.url.toString(), 'method': snapshot.method,
            'headers': snapshot.headers, 'revision': snapshot.revision,
            'policy': snapshot.policy.values,
            'generation': snapshot.generation, 'limit': snapshot.limit, 'executionAllowed': false,
          });
        case 'prepareNativeHTTPRetry':
          _keys(values, {'requestID', 'leaseID', 'attempt'});
          final leaseID = _id(values['leaseID']);
          final attempt = values['attempt'];
          if (attempt is! int || attempt < 1) throw const NativeHTTPRequestLeaseException('invalidArguments');
          final headers = await service.prepareRetry(requestID: requestID, leaseID: leaseID, attempt: attempt);
          return Map.unmodifiable({
            'state': 'retryPrepared', 'requestID': requestID.toLowerCase(), 'leaseID': leaseID.toLowerCase(),
            'attempt': attempt, 'headers': headers, 'executionAllowed': false,
          });
        case 'prepareNativeHTTPRedirect':
          _keys(values, {'requestID', 'leaseID', 'redirectIndex', 'response'});
          final leaseID = _id(values['leaseID']);
          final index = _positiveInt(values['redirectIndex']);
          final prepared = await service.prepareRedirect(requestID: requestID, leaseID: leaseID,
            redirectIndex: index, response: _response(values['response']));
          return Map.unmodifiable({
            'state': 'redirectPrepared', 'requestID': requestID.toLowerCase(), 'leaseID': leaseID.toLowerCase(),
            'redirectIndex': index, 'url': prepared.url.toString(), 'headers': prepared.headers,
            'remainingRedirects': prepared.remainingRedirects, 'executionAllowed': false,
          });
        case 'finishNativeHTTPRequest':
          _keys(values, {'requestID', 'leaseID', 'response', 'redirectIndex'},
            required: {'requestID', 'leaseID', 'response'});
          final leaseID = _id(values['leaseID']);
          return _receipt(await service.finish(
            requestID: requestID, leaseID: leaseID,
            redirectIndex: values.containsKey('redirectIndex') ? _positiveInt(values['redirectIndex']) : 0,
            response: _response(values['response']),
          ));
        case 'abandonNativeHTTPRequest':
          _keys(values, {'requestID', 'leaseID'}, required: {'requestID'});
          final abandonLeaseID = values.containsKey('leaseID') ? _id(values['leaseID']) : null;
          return _receipt(service.abandon(requestID: requestID, leaseID: abandonLeaseID));
        default:
          throw const NativeHTTPRequestLeaseException('unsupportedCommand');
      }
    } on NativeHTTPRequestLeaseException catch (error) {
      return Map.unmodifiable({'state': 'error', 'code': error.code, 'executionAllowed': false});
    }
  }

  void dispose() => service.dispose();

  static Map<String, Object?> _receipt(NativeHTTPRequestLeaseReceipt receipt) => Map.unmodifiable({
    'state': receipt.outcome.name, 'cookiesSaved': receipt.cookiesSaved,
    'cookieCount': receipt.cookieCount, 'executionAllowed': false,
  });

  static NativeHTTPRequestLeaseResponse _response(Object? value) {
    final response = _map(value);
    const responseKeys = {'url', 'statusCode', 'cookieSource', 'setCookieValues'};
    _keys(response, {...responseKeys, 'redirects', 'locationValues'}, required: responseKeys);
    final statusCode = response['statusCode'];
    if (statusCode is! int) throw const NativeHTTPRequestLeaseException('invalidArguments');
    final source = switch (response['cookieSource']) {
      'separatedFields' => SetCookieSource.separatedFields,
      'foundationCombined' => SetCookieSource.foundationCombined,
      'dioLegacyPossiblyFolded' => SetCookieSource.dioLegacyPossiblyFolded,
      _ => throw const NativeHTTPRequestLeaseException('invalidArguments'),
    };
    return NativeHTTPRequestLeaseResponse(url: _url(response['url']), statusCode: statusCode,
      cookieSource: source, setCookieValues: _strings(response['setCookieValues']),
      redirects: response.containsKey('redirects') ? _redirects(response['redirects']) : const [],
      locationValues: response.containsKey('locationValues') ? _strings(response['locationValues']) : null);
  }

  static int _positiveInt(Object? value) {
    if (value is! int || value < 1) throw const NativeHTTPRequestLeaseException('invalidArguments');
    return value;
  }

  static Map<String, Object?> _map(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const NativeHTTPRequestLeaseException('invalidArguments');
    }
    return {for (final entry in value.entries) entry.key as String: entry.value};
  }

  static String _id(Object? value) {
    if (value is! String || !NativeHTTPRequestLeaseService.isValidID(value)) {
      throw const NativeHTTPRequestLeaseException('invalidArguments');
    }
    return value;
  }

  static Uri _url(Object? value) {
    final url = value is String ? Uri.tryParse(value) : null;
    if (url == null) throw const NativeHTTPRequestLeaseException('invalidArguments');
    return url;
  }

  static List<String> _strings(Object? value) {
    if (value is! List || value.any((item) => item is! String)) {
      throw const NativeHTTPRequestLeaseException('invalidArguments');
    }
    return value.cast<String>();
  }

  static List<NativeHTTPRequestRedirectHop> _redirects(Object? value) {
    const invalid = NativeHTTPRequestLeaseException('invalidArguments');
    if (value is! List || value.isEmpty) throw invalid;
    return value.map((entry) {
      final hop = _map(entry);
      _keys(hop, {'statusCode', 'location', 'url'});
      final status = hop['statusCode'];
      final location = hop['location'];
      if (status is! int || location is! String) throw invalid;
      return NativeHTTPRequestRedirectHop(statusCode: status, location: location, url: _url(hop['url']));
    }).toList();
  }

  static void _keys(Map<String, Object?> values, Set<String> allowed, {Set<String>? required}) {
    if (values.keys.any((key) => !allowed.contains(key)) ||
        !(required ?? allowed).every(values.containsKey)) {
      throw const NativeHTTPRequestLeaseException('invalidArguments');
    }
  }
}
