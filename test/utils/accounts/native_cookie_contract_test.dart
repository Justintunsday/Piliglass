import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_test_storage.dart';

List<Map<String, Object?>> _records(DefaultCookieJar jar) {
  final records = <Map<String, Object?>>[];
  for (final bucket in [(hostOnly: false, values: jar.domainCookies), (hostOnly: true, values: jar.hostCookies)]) {
    for (final domain in bucket.values.entries) {
      for (final path in domain.value.entries) {
        for (final stored in path.value.values) {
          final cookie = stored.cookie;
          records.add({
            'name': cookie.name, 'value': cookie.value, 'domain': domain.key, 'path': path.key,
            'hostOnly': bucket.hostOnly, 'cookieDomain': cookie.domain, 'cookiePath': cookie.path,
            'secure': cookie.secure, 'httpOnly': cookie.httpOnly, 'sameSite': cookie.sameSite?.name,
            'expiresMicroseconds': cookie.expires?.microsecondsSinceEpoch,
            'maxAgeSeconds': cookie.maxAge, 'createdSeconds': stored.createTimeStamp, 'sequence': records.length,
          });
        }
      }
    }
  }
  return records;
}

void main() {
  late AccountTestStorage storage;
  setUpAll(() async { storage = await AccountTestStorage.open(); });
  tearDownAll(() => storage.close());

  test('actual Dart Cookie parser and CookieJar generate native compatibility golden', () async {
    const createdSeconds = 1700000000;
    final parserCases = <Map<String, Object?>>[];
    const fields = [
      'a=one', 'a=', 'a=;', 'a=   ', 'a=one=two', ' a \t= b \t; Path= /x \t',
      'a="quoted"', 'a="has space"', 'a=bad,value', 'a=bad\\value', '=missing', 'bad name=value',
      'a=value; Secure; HttpOnly', 'a=value; Secure=', 'a=value; HttpOnly=true',
      'a=value; SameSite=lax', 'a=value; SameSite=None; Secure', 'a=value; SameSite=None',
      'a=value; SameSite=bad', 'a=value; SameSite', 'a=value; SameSite=Strict', 'a=value; SameSite=sTrIcT',
      'a=value; Domain=.bilibili.com; Path=/x', 'a=value; Domain=', 'a=value; Domain; Path',
      'a=value; Path=/x,comma', 'a=value; Path=/x; Path=/last',
      'a=value; Max-Age=16', 'a=value; Max-Age=+16', 'a=value; Max-Age=-16',
      'a=value; Max-Age=0x10', 'a=value; Max-Age=0xffffffffffffffff', 'a=value; Max-Age=9223372036854775808',
      'a=value; Max-Age=', 'a=value; Max-Age',
      'a=value; Expires=Wed, 09 Jun 2027 10:18:14 GMT',
      'a=value; Expires=Sunday, 06-Nov-94 08:49:37 GMT',
      'a=value; Expires=Sun Nov  6 08:49:37 1994',
      'a=value; Expires=9 Jun 2027 1:2:3', 'a=value; Expires=2027 Jun 09 1:2:3',
      'a=value; Expires=29 Feb 2028 00:00:00', 'a=value; Expires=29 Feb 2027 00:00:00',
      'a=value; Expires=09 Jun 69 10:18:14', 'a=value; Expires=09 Jun 70 10:18:14',
      'a=value; Expires=09 Jun 2027 25:18:14', 'a=value; Expires=09 Jun 2027 10a:18:14',
      'a=value; Expires=09 May\u0301 2027 10:18:14', 'a=value; Expires=invalid',
      'a=value; Expires', 'a=value; Unknown=retained-only-as-ignored-extension',
    ];
    final uri = Uri.parse('https://api.bilibili.com/x/test');
    for (final raw in fields) {
      final item = <String, Object?>{'raw': raw, 'url': uri.toString(), 'createdSeconds': createdSeconds};
      try {
        final parsed = Cookie.fromSetCookieValue(raw);
        final jar = DefaultCookieJar(ignoreExpires: true);
        await jar.saveFromResponse(uri, [parsed]);
        for (final domain in [...jar.domainCookies.values, ...jar.hostCookies.values]) {
          for (final path in domain.values) {
            for (final stored in path.values) { stored.createTimeStamp = createdSeconds; }
          }
        }
        item['record'] = _records(jar).single;
        item['accepted'] = true;
      } catch (_) { item['accepted'] = false; }
      parserCases.add(item);
    }

    final selections = <Map<String, Object?>>[];
    for (final ignoreExpires in [false, true]) {
      final jar = DefaultCookieJar(ignoreExpires: ignoreExpires);
      await jar.saveFromResponse(uri, [
        Cookie.fromSetCookieValue('same=root; Domain=.bilibili.com; Path=/'),
        Cookie.fromSetCookieValue('same=nested; Domain=.bilibili.com; Path=/x'),
        Cookie.fromSetCookieValue('host=pathless'),
        Cookie.fromSetCookieValue('secure_live=yes; Secure; Path=/x'),
        Cookie.fromSetCookieValue('secure_expired=legacy; Secure; Path=/x'),
        Cookie.fromSetCookieValue('ordinary_expired=no; Path=/x'),
        Cookie.fromSetCookieValue('case_path=legacy; Domain=.bilibili.com; Path=/X'),
        Cookie.fromSetCookieValue('other_host=no; Domain=other.example; Path=/'),
      ]);
      final now = DateTime.now().microsecondsSinceEpoch;
      for (final name in ['secure_expired', 'ordinary_expired']) {
        final stored = jar.hostCookies[uri.host]!['/x']![name]!;
        stored.cookie.maxAge = 1;
        stored.createTimeStamp = now ~/ 1000000 - 1000;
      }
      final records = _records(jar);
      for (final url in [
        'https://api.bilibili.com/x/test', 'http://api.bilibili.com/x/test',
        'https://api.bilibili.com/X/TEST', 'https://api.bilibili.com/docsets',
        'https://bilibili.com/x/test', 'https://notbilibili.com/x/test',
      ]) {
        final loaded = await jar.loadForRequest(Uri.parse(url));
        final header = AccountManager.getCookies(loaded);
        selections.add({'url': url, 'nowMicroseconds': now, 'ignoreExpires': ignoreExpires,
          'cookies': records, 'header': header});
      }
    }
    final directory = Directory('build/native-cookie-contracts');
    await directory.create(recursive: true);
    await File('${directory.path}/dart.json').writeAsString(jsonEncode({
      'source': 'actual Dart Cookie.fromSetCookieValue / CookieJar 4.0.9 / AccountManager.getCookies',
      'parserCases': parserCases, 'selections': selections,
    }));
    expect(parserCases.where((item) => item['accepted'] == true).length, greaterThan(20));
    expect(selections.length, 12);
    final http = selections.firstWhere((s) => s['url'] == 'http://api.bilibili.com/x/test' && s['ignoreExpires'] == false);
    expect(http['header'], contains('secure_live=yes'));
    expect(http['header'], isNot(contains('secure_expired=legacy')));
    final https = selections.firstWhere((s) => s['url'] == 'https://api.bilibili.com/x/test' && s['ignoreExpires'] == false);
    expect(https['header'], contains('secure_expired=legacy'));
    expect(https['header'], isNot(contains('ordinary_expired=no')));
  });
}
