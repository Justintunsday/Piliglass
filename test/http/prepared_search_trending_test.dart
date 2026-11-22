import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models_new/search/search_trending/data.dart';
import 'package:PiliPlus/services/native_accounts/native_account_snapshot_bridge.dart';
import 'package:PiliPlus/services/native_accounts/native_account_snapshot_service.dart';
import 'package:PiliPlus/services/native_http/native_http_request_lease_bridge.dart';
import 'package:PiliPlus/services/native_http/native_http_request_lease_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter_test/flutter_test.dart';

import '../utils/accounts/account_test_storage.dart';

enum _Scenario {
  selected,
  switched,
  revoked,
  httpError,
  corrupt,
  declined,
  redirects,
  redirected,
  redirectedSwitched,
  redirectedHTTPError,
  retried,
  retryRevoked,
  bodyRetried,
  bodyRetryExhausted,
  terminalRedirect,
  redirectedTerminal,
  interceptorSuccess,
  interceptorDenied,
  interceptorExhausted,
  interceptorCorrupt,
  interceptorRevoked;

  bool get usesInterceptor => switch (this) {
    interceptorSuccess || interceptorDenied || interceptorExhausted || interceptorCorrupt || interceptorRevoked => true,
    _ => false,
  };
}

LoginAccount _account(int mid, String session) => LoginAccount(
  BiliCookieJar.fromJson({
    'DedeUserID': '$mid',
    'SESSDATA': 'fixture-$session',
  }),
  null,
  null,
)..activated = true;

Future<List<String>> _responseCookies(Account account, Uri url) async => [
  for (final cookie in await account.cookieJar.loadForRequest(url))
    if (cookie.name == 'trending_fixture') cookie.value,
];

const _gzipHeaders = {'content-encoding': ['gzip']};

List<int> _trendingBody() => gzip.encode([
  0xef, 0xbb, 0xbf,
  ...utf8.encode(jsonEncode({
    'code': 0,
    'data': {'list': [
      {'keyword': '热搜测试', 'recommend_reason': '开源·工具·验证', 'icon': '//example.test/trending'},
      {'keyword': ''},
    ]},
  })),
]);

List<Map<String, String>> _trendingKeywords(List<int> body) {
  final decoded = jsonDecode(utf8.decode(Request.responseBytesDecoder(body, _gzipHeaders), allowMalformed: true))
      as Map<String, dynamic>;
  final expected = SearchTrendingData.fromJson(decoded['data'] as Map<String, dynamic>);
  return [
    for (final item in expected.list!)
      if (item.keyword.isNotEmpty)
        {'keyword': item.keyword, 'reason': item.recommendReason ?? '', 'icon': 'https:${item.icon}'},
  ];
}

Future<Map<String, Object?>> _interceptorCase(
  _Scenario scenario, NativeHTTPRequestLeaseBridge bridge, LoginAccount original, LoginAccount other,
  Map<String, Object?> prepared,
) async {
  final start = Uri.parse(prepared['url'] as String);
  final ids = {'requestID': prepared['requestID'], 'leaseID': prepared['leaseID']};
  final corrupt = scenario == _Scenario.interceptorCorrupt;
  final revoked = scenario == _Scenario.interceptorRevoked;
  final exhausted = scenario == _Scenario.interceptorExhausted;
  final denied = scenario == _Scenario.interceptorDenied;
  final abandoning = corrupt || revoked;
  final target = start.resolve('next/target?step=1&limit=10');
  await original.cookieJar.saveFromResponse(target, [Cookie('next_scope', 'present')..path = target.resolve('.').path]);
  if (denied) await Accounts.set(AccountType.recommend, other);
  if (revoked) await Accounts.installCredentials(_account(original.mid, 'replacement'));

  final reissues = <Map<String, Object?>>[];
  final intermediate = <Map<String, Object?>>[];
  var current = start;
  var redirectIndex = 0;
  for (final location in ['next/target?step=1', if (exhausted) 'final/result?step=2']) {
    const hop = 'nested/first?automatic=1';
    final followed = redirectIndex == 0 && !exhausted;
    final responseUrl = followed ? current.resolve(hop) : current;
    final head = <String, Object?>{
      'url': responseUrl.toString(), 'statusCode': 300, 'cookieSource': 'separatedFields',
      'setCookieValues': ['trending_fixture=intermediate; Path=/'], 'locationValues': [location],
      if (followed) 'redirects': [{'statusCode': 302, 'location': hop, 'url': responseUrl.toString()}],
    };
    intermediate.add({'head': head, 'body': base64Encode(utf8.encode(corrupt ? 'malformed JSON' : '{}'))});
    if (corrupt) break;
    final command = {
      ...ids, 'redirectIndex': redirectIndex + 1,
      'response': {...head, 'setCookieValues': <String>[]},
    };
    final reply = await bridge.handle('prepareNativeHTTPRedirect', command);
    reissues.add({'command': command, 'reply': reply});
    if (revoked) {
      expect(reply['code'], 'revoked');
      break;
    }
    expect(reply['state'], 'redirectPrepared');
    expect(reply['executionAllowed'], isFalse);
    current = current.resolve('$location&limit=10');
    expect(reply['url'], current.toString());
    expect(reply['remainingRedirects'], 2 - ++redirectIndex);
    final header = (reply['headers'] as Map)['cookie'] as String;
    expect(header, contains('SESSDATA=fixture-recommend'));
    expect(header, contains('next_scope=present'));
    expect(header, isNot(contains('trending_fixture=intermediate')));
  }

  const last = 'terminal/response?automatic=2';
  const extra = 'extra/destination';
  final responseUrl = exhausted ? current : current.resolve(last);
  final terminal = <String, Object?>{
    ...ids,
    if (!abandoning) ...{
      'redirectIndex': redirectIndex,
      'response': {
        'url': responseUrl.toString(), 'statusCode': denied ? 403 : (exhausted ? 300 : 200),
        'cookieSource': 'separatedFields', 'setCookieValues': ['trending_fixture=terminal'],
        if (exhausted) 'locationValues': [extra],
        if (!exhausted) 'redirects': [{'statusCode': 307, 'location': last, 'url': responseUrl.toString()}],
      },
    },
  };
  final revision = Accounts.requestRevision;
  final method = abandoning ? 'abandonNativeHTTPRequest' : 'finishNativeHTTPRequest';
  final receipt = await bridge.handle(method, terminal);
  expect(receipt['state'], abandoning ? 'abandoned' : 'finished');
  expect(receipt['cookieCount'], abandoning ? 0 : 1);
  expect(Accounts.requestRevision - revision, abandoning ? 0 : (exhausted ? 6 : (denied ? 2 : 1)));
  expect(await _responseCookies(original, start), isEmpty);
  expect(await _responseCookies(original, responseUrl), abandoning ? <String>[] : ['terminal']);
  expect(await _responseCookies(other, responseUrl), isEmpty);
  if (exhausted) {
    // The nested destination matches both Cookie paths.
    expect(await _responseCookies(original, current.resolve(extra)), ['terminal', 'terminal']);
  }
  expect(bridge.service.liveLeaseCount, 0);
  expect((await bridge.handle(method, terminal))['state'], 'consumed');
  final snapshot = await NativeAccountSnapshotBridge(NativeAccountSnapshotService())
      .handle('loadNativeAccountSelection', null);
  final body = _trendingBody();
  return {
    'reissues': reissues, 'intermediate': intermediate, 'retries': [],
    'terminalMethod': method, 'terminal': terminal, 'receipt': receipt, 'selection': snapshot,
    'body': base64Encode(body), 'keywords': _trendingKeywords(body),
  };
}

void main() {
  late AccountTestStorage storage;
  final cases = <Map<String, Object?>>[];

  setUpAll(() async {
    storage = await AccountTestStorage.open(replaceHTTPAdapter: false);
  });
  tearDownAll(() async {
    await storage.close();
    if (cases.length != _Scenario.values.length) return;
    final output = File('build/prepared-http-policy/trending.json');
    await output.parent.create(recursive: true);
    await output.writeAsString(jsonEncode({'version': 1, 'cases': cases}));
  });

  for (final scenario in _Scenario.values) {
    test(
      'prepared trending ${scenario.name} uses the real account bridge',
      () async {
        final mid = 32000 + 2 * scenario.index;
        final original = _account(mid, 'recommend');
        final other = _account(mid + 1, 'main');
        await Accounts.installCredentials(original);
        await Accounts.installCredentials(other);
        Accounts.selectTemporarily(AccountType.main, other);
        await Accounts.set(AccountType.recommend, original);

        final redirected = switch (scenario) {
          _Scenario.redirected || _Scenario.redirectedSwitched ||
          _Scenario.redirectedHTTPError || _Scenario.redirectedTerminal ||
          _Scenario.retried || _Scenario.bodyRetried => true,
          _ => false,
        };
        final followsRedirects = redirected || scenario == _Scenario.redirects || scenario.usesInterceptor;
        final retryRevoked = scenario == _Scenario.retryRevoked;
        final bodyRetryExhausted = scenario == _Scenario.bodyRetryExhausted;
        final retrying = retryRevoked || bodyRetryExhausted ||
            scenario == _Scenario.retried || scenario == _Scenario.bodyRetried;
        if (retrying || scenario.usesInterceptor) {
          final retry = RetryInterceptor(Request.dio, retrying ? 2 : 0, 500);
          Request.dio.interceptors.insert(0, retry);
          addTearDown(() => Request.dio.interceptors.remove(retry));
        }
        final previousRedirects = Request.dio.options.followRedirects;
        final previousLimit = Request.dio.options.maxRedirects;
        Request.dio.options.followRedirects = followsRedirects;
        if (scenario.usesInterceptor) Request.dio.options.maxRedirects = 2;
        addTearDown(() {
          Request.dio.options.followRedirects = previousRedirects;
          Request.dio.options.maxRedirects = previousLimit;
        });
        final service = NativeHTTPRequestLeaseService(autoExpire: false);
        final bridge = NativeHTTPRequestLeaseBridge(service: service);
        addTearDown(bridge.dispose);

        final prepare = {
          'requestID':
              'ab000000-0000-4000-8000-${mid.toString().padLeft(12, '0')}',
          'purpose': 'searchTrending',
          'limit': 10,
        };
        final prepared = await bridge.handle(
          'prepareNativeHTTPRequest',
          prepare,
        );
        expect(prepared['state'], 'prepared');
        expect(prepared['executionAllowed'], isFalse);
        expect(
          (prepared['policy'] as Map)['followRedirects'],
          followsRedirects,
        );
        final cookie = (prepared['headers'] as Map)['cookie'] as String;
        expect(cookie, contains('SESSDATA=fixture-recommend'));
        expect(cookie, isNot(contains('SESSDATA=fixture-main')));

        if (scenario.usesInterceptor) {
          cases.add({'name': scenario.name, 'prepare': prepare, 'prepared': prepared,
            ...await _interceptorCase(scenario, bridge, original, other, prepared)});
          return;
        }

        final url = Uri.parse(prepared['url'] as String);
        final responseUrl = redirected ? url.resolve('/fixture/nested/response?limit=10') : url;
        final cookieUrl = redirected ? url.resolve('response?limit=10') : url;
        final status = switch (scenario) {
          _Scenario.httpError || _Scenario.redirectedHTTPError => 403,
          _Scenario.terminalRedirect => 302,
          _Scenario.redirectedTerminal => 300,
          _ => 200,
        };
        final locations = switch (scenario) {
          _Scenario.terminalRedirect => ['/fixture/comma,kept/next', '/fixture/second/next'],
          _Scenario.redirectedTerminal => [url.resolve('/fixture/absolute/next').toString()],
          _ => null,
        };
        final fields = [
          if (redirected || locations != null)
            'trending_fixture=endpoint'
          else
            'trending_fixture=endpoint; Path=/x/v2/search',
          'trending_fixture=root; Domain=.bilibili.com; Path=/',
        ];
        final declined =
            scenario == _Scenario.declined || scenario == _Scenario.redirects;
        final abandoning = declined || retryRevoked || bodyRetryExhausted;
        final terminalMethod = abandoning
            ? 'abandonNativeHTTPRequest'
            : 'finishNativeHTTPRequest';
        final terminal = <String, Object?>{
          'requestID': prepared['requestID'],
          'leaseID': prepared['leaseID'],
          if (!abandoning)
            'response': {
              'url': responseUrl.toString(),
              'statusCode': status,
              'cookieSource': 'separatedFields',
              'setCookieValues': fields,
              'locationValues': ?locations,
              if (redirected)
                'redirects': [
                  {
                    'statusCode': 302,
                    'location': '/fixture/nested/stage',
                    'url': url.resolve('/fixture/nested/stage').toString(),
                  },
                  {
                    'statusCode': 307,
                    'location': 'response?limit=10',
                    'url': responseUrl.toString(),
                  },
                ],
            },
        };
        if (scenario == _Scenario.switched || scenario == _Scenario.redirectedSwitched) {
          await Accounts.set(AccountType.recommend, other);
        } else if (scenario == _Scenario.revoked || retryRevoked) {
          await Accounts.installCredentials(_account(mid, 'replacement'));
        }
        final retries = <Map<String, Object?>>[];
        if (retrying) {
          for (final attempt in retryRevoked ? [1] : [1, 2]) {
            if (!retryRevoked) {
              await original.cookieJar.saveFromResponse(url, [Cookie('retry_fixture', 'attempt-$attempt')..path = '/']);
            }
            final command = {'requestID': prepared['requestID'], 'leaseID': prepared['leaseID'], 'attempt': attempt};
            final reply = await bridge.handle('prepareNativeHTTPRetry', command);
            expect(reply['state'], retryRevoked ? 'error' : 'retryPrepared');
            expect(reply['executionAllowed'], isFalse);
            if (retryRevoked) {
              expect(reply['code'], 'revoked');
            } else {
              final header = (reply['headers'] as Map)['cookie'] as String;
              expect(header, contains('retry_fixture=attempt-$attempt'));
              expect(header, contains('SESSDATA=fixture-recommend'));
            }
            retries.add({'command': command, 'reply': reply});
          }
        }
        final receipt = await bridge.handle(terminalMethod, terminal);
        final writes = !abandoning && scenario != _Scenario.revoked;
        expect(receipt['state'], switch (scenario) {
          _Scenario.declined || _Scenario.redirects || _Scenario.retryRevoked || _Scenario.bodyRetryExhausted => 'abandoned',
          _Scenario.revoked => 'revoked',
          _ => 'finished',
        });
        expect(receipt['cookieCount'], writes ? fields.length : 0);
        expect(
          await _responseCookies(original, cookieUrl),
          unorderedEquals(
            writes ? ['endpoint', 'root'] : <String>[],
          ),
        );
        expect(await _responseCookies(other, cookieUrl), isEmpty);
        if (locations != null) {
          for (final location in locations) {
            final destination = url.resolve(location);
            expect(await _responseCookies(original, destination), unorderedEquals(['endpoint', 'root']));
            expect(await _responseCookies(other, destination), isEmpty);
          }
        }
        if (redirected) {
          // A host-only Cookie without Path uses the legacy directory, even
          // though the final body arrived at a different same-origin path.
          expect(await _responseCookies(original, responseUrl), ['root']);
          expect(await _responseCookies(other, responseUrl), isEmpty);
          final replay = await bridge.handle(terminalMethod, terminal);
          expect(replay['state'], 'consumed');
          expect(replay['cookiesSaved'], isFalse);
        }
        if (scenario == _Scenario.revoked || retryRevoked) {
          final current = Accounts.account.get('$mid')!;
          expect(current, isNot(same(original)));
          expect(await _responseCookies(current, url), isEmpty);
        }
        expect(service.liveLeaseCount, 0);

        final snapshot = await NativeAccountSnapshotBridge(
          NativeAccountSnapshotService(),
        ).handle('loadNativeAccountSelection', null);
        expect(snapshot['authority'], 'dartHive');

        final gzipBody = _trendingBody();
        final wireBody = [...gzipBody];
        if (scenario == _Scenario.corrupt || status == 403) {
          wireBody[wireBody.length - 8] ^= 1;
          expect(
            () => Request.responseBytesDecoder(wireBody, _gzipHeaders),
            throwsFormatException,
          );
        }
        cases.add({
          'name': scenario.name,
          'prepare': prepare,
          'prepared': prepared,
          'retries': retries,
          'terminalMethod': terminalMethod,
          'terminal': terminal,
          'receipt': receipt,
          'selection': snapshot,
          'body': base64Encode(wireBody),
          'keywords': _trendingKeywords(gzipBody),
        });
      },
    );
  }
}
