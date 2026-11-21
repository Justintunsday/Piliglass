import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/init.dart';
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

enum _Scenario { selected, switched, revoked, httpError, corrupt, declined }

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
        final cookie = (prepared['headers'] as Map)['cookie'] as String;
        expect(cookie, contains('SESSDATA=fixture-recommend'));
        expect(cookie, isNot(contains('SESSDATA=fixture-main')));

        final url = Uri.parse(prepared['url'] as String);
        final status = scenario == _Scenario.httpError ? 403 : 200;
        const fields = [
          'trending_fixture=endpoint; Path=/x/v2/search',
          'trending_fixture=root; Domain=.bilibili.com; Path=/',
        ];
        final declined = scenario == _Scenario.declined;
        final terminalMethod = declined
            ? 'abandonNativeHTTPRequest'
            : 'finishNativeHTTPRequest';
        final terminal = <String, Object?>{
          'requestID': prepared['requestID'],
          'leaseID': prepared['leaseID'],
          if (!declined)
            'response': {
              'url': url.toString(),
              'statusCode': status,
              'cookieSource': 'separatedFields',
              'setCookieValues': fields,
            },
        };
        if (scenario == _Scenario.switched) {
          await Accounts.set(AccountType.recommend, other);
        } else if (scenario == _Scenario.revoked) {
          await Accounts.installCredentials(_account(mid, 'replacement'));
        }
        final receipt = await bridge.handle(terminalMethod, terminal);
        final writes = !declined && scenario != _Scenario.revoked;
        expect(receipt['state'], switch (scenario) {
          _Scenario.declined => 'abandoned',
          _Scenario.revoked => 'revoked',
          _ => 'finished',
        });
        expect(receipt['cookieCount'], writes ? fields.length : 0);
        expect(
          await _responseCookies(original, url),
          unorderedEquals(
            writes ? ['endpoint', 'root'] : <String>[],
          ),
        );
        expect(await _responseCookies(other, url), isEmpty);
        if (scenario == _Scenario.revoked) {
          final current = Accounts.account.get('$mid')!;
          expect(current, isNot(same(original)));
          expect(await _responseCookies(current, url), isEmpty);
        }
        expect(service.liveLeaseCount, 0);

        final snapshot = await NativeAccountSnapshotBridge(
          NativeAccountSnapshotService(),
        ).handle('loadNativeAccountSelection', null);
        expect(snapshot['authority'], 'dartHive');

        final gzipBody = gzip.encode([
          0xef,
          0xbb,
          0xbf,
          ...utf8.encode(
            jsonEncode({
              'code': 0,
              'data': {
                'list': [
                  {
                    'keyword': '热搜测试',
                    'recommend_reason': '开源·工具·验证',
                    'icon': '//example.test/trending',
                  },
                  {'keyword': ''},
                ],
              },
            }),
          ),
        ]);
        const gzipHeaders = {
          'content-encoding': ['gzip'],
        };
        final wireBody = [...gzipBody];
        if (scenario == _Scenario.corrupt || scenario == _Scenario.httpError) {
          wireBody[wireBody.length - 8] ^= 1;
          expect(
            () => Request.responseBytesDecoder(wireBody, gzipHeaders),
            throwsFormatException,
          );
        }
        final decoded = jsonDecode(
          utf8.decode(
            Request.responseBytesDecoder(gzipBody, gzipHeaders),
            allowMalformed: true,
          ),
        ) as Map<String, dynamic>;
        final expected = SearchTrendingData.fromJson(
          decoded['data'] as Map<String, dynamic>,
        );
        cases.add({
          'name': scenario.name,
          'prepare': prepare,
          'prepared': prepared,
          'terminalMethod': terminalMethod,
          'terminal': terminal,
          'receipt': receipt,
          'selection': snapshot,
          'body': base64Encode(wireBody),
          'keywords': [
            for (final item in expected.list!)
              if (item.keyword.isNotEmpty)
                {
                  'keyword': item.keyword,
                  'reason': item.recommendReason ?? '',
                  'icon': 'https:${item.icon}',
                },
          ],
        });
      },
    );
  }
}
