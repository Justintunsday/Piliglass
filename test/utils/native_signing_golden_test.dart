import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/utils/app_sign.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/utils/wbi_sign.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, Object?>> fields(Map<String, dynamic> params) => [
  for (final entry in params.entries)
    {
      'key': entry.key,
      'type': switch (entry.value) {
        String() => 'string',
        bool() => 'boolean',
        int() => 'integer',
        List<String>() => 'strings',
        null => 'null',
        _ => throw StateError('Unsupported fixture value'),
      },
      'value': entry.value is int ? entry.value.toString() : entry.value,
    },
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const epoch = 1735689601;
  const source = '0123456789abcdef0123456789abcdef'
      'fedcba9876543210fedcba9876543210';
  const appKey = 'fixture-app-key';
  const appSecret = 'fixture-app-secret';
  final wbiCases = <Map<String, Object>>[
    {},
    {'b': 0, 'a': true, 'wts': 'old', 'text': " !'()*+%&=~_-.", 'empty': ''},
    {'中文': '弹幕🙂', 'é': 'composed', 'e\u0301': 'decomposed', '😀': 'a', '\uE000': 'b'},
    {'old': -9223372036854775808, 'large': 9007199254740993, 'w_rid': 'previous-digest'},
    {'list': <String>['a b', 'x!'], 'emptyList': <String>[]},
    {'from_url': Uri.encodeComponent('https://www.bilibili.com/a?x=1&y=a b'), 'line': '\r\n\t',
      'combiningPunctuation': '!\u0301(\u0301*\u0301'},
  ];
  final appCases = <Map<String, dynamic>>[
    {},
    {'z': '', 'a': " !'()*+%&=~_-.", 'flag': false, 'count': 9007199254740993},
    {'list': <String>['a b', '', '中文🙂', '+%'], 'emptyList': <String>[]},
    {'é': 'composed', 'e\u0301': 'decomposed', '😀': 'a', '\uE000': 'b'},
    {'appkey': 'old-key', 'ts': 123, 'sign': 'previous-digest', 'min': -9223372036854775808},
    {'dt': Uri.encodeComponent('device +/='), 'from_url': Uri.encodeComponent('https://www.bilibili.com/a?x=a b')},
  ];

  test('actual Dart signers export deterministic native migration goldens', () async {
    final mixin = WbiSign.getMixinKey(source);
    final records = <Map<String, Object?>>[];
    for (var index = 0; index < wbiCases.length; index++) {
      final params = Map<String, Object>.from(wbiCases[index]);
      final input = fields(params);
      final query = WbiSign.makeSigningQuery({...params, 'wts': epoch});
      WbiSign.encWbi(params, mixin, epochSeconds: epoch);
      records.add({'name': 'wbi-$index', 'kind': 'wbi', 'epochSeconds': '$epoch',
        'input': input, 'mixinKey': mixin, 'query': query, 'digest': params['w_rid'],
        'output': fields(params)});
      final secondInput = fields(params);
      final secondQuery = WbiSign.makeSigningQuery({...params, 'wts': epoch});
      WbiSign.encWbi(params, mixin, epochSeconds: epoch);
      records.add({'name': 'wbi-$index-repeat', 'kind': 'wbi', 'epochSeconds': '$epoch',
        'input': secondInput, 'mixinKey': mixin, 'query': secondQuery,
        'digest': params['w_rid'], 'output': fields(params)});
    }
    for (var index = 0; index < appCases.length; index++) {
      final params = Map<String, dynamic>.from(appCases[index]);
      final input = fields(params);
      final query = AppSign.makeSigningQuery({...params, 'appkey': appKey, 'ts': '$epoch'});
      AppSign.appSign(params, appkey: appKey, appsec: appSecret, epochSeconds: epoch);
      records.add({'name': 'app-$index', 'kind': 'app', 'epochSeconds': '$epoch',
        'input': input, 'appKey': appKey, 'appSecret': appSecret, 'query': query,
        'digest': params['sign'], 'output': fields(params), 'allowReleaseNullValues': false});
    }
    final keyURLs = [
      ['https://fixture.invalid/$source.png', 'https://fixture.invalid/0123456789abcdef0123456789abcdef.png?x=.txt'],
      ['https://fixture.invalid/${source.substring(0, 32)}', 'https://fixture.invalid/${source.substring(32)}'],
    ];
    final navKeys = [
      for (final urls in keyURLs)
        {'imageURL': urls[0], 'subURL': urls[1],
          'mixinKey': WbiSign.getMixinKey(Utils.getFileName(urls[0], fileExt: false) +
            Utils.getFileName(urls[1], fileExt: false))},
    ];
    final output = File('build/native-signing-check/dart-golden.json');
    await output.parent.create(recursive: true);
    await output.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'source': 'actual WbiSign.encWbi/AppSign.appSign + production query helpers',
      'assertionsEnabled': true, 'mixinSource': source, 'mixinKey': mixin,
      'records': records, 'navKeys': navKeys,
      'encoding': [for (final text in ['', ' a+b%&=', "-_.!~*'()", '中文🙂', 'e\u0301', '\u0000\r\n'])
        {'input': text, 'output': Uri.encodeComponent(text)}],
    }));
    expect(records, hasLength(18));
    expect(WbiSign.getMixinKey(source), hasLength(32));
    expect(records[1]['digest'], isNot(records[0]['digest']));
  });

  test('AppSign debug null asserts; signer leaves the previous sign in query', () {
    expect(() => AppSign.appSign({'null': null}, epochSeconds: epoch), throwsAssertionError);
    final params = <String, dynamic>{'sign': 'old'};
    expect(AppSign.makeSigningQuery(params), 'sign=old');
    params.remove('sign'); // AccountManager is responsible for this cleanup.
    expect(AppSign.makeSigningQuery(params), isEmpty);
  });

  test('WBI source uses UTF16 units and malformed length fails explicitly', () {
    expect(() => WbiSign.getMixinKey('short'), throwsRangeError);
    final key = WbiSign.getMixinKey('🙂' * 32);
    expect(key.codeUnits, hasLength(32));
    final output = File('build/native-signing-check/dart-mixin-surrogates.json');
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(jsonEncode({'source': '🙂' * 32, 'units': key.codeUnits}));
  });
}
