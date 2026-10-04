import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';

import 'package:PiliPlus/utils/accounts/account_manager/response_cookie_headers.dart';

int checks = 0;

void expect(bool condition, String message) {
  if (!condition) throw StateError(message);
  checks++;
}

ParsedSetCookieHeaders parse(
  List<String> values, [
  SetCookieSource source = SetCookieSource.dioLegacyPossiblyFolded,
]) => parseResponseCookieHeaders(values, source: source);

void expectMalformed(List<String> values) {
  try {
    parse(values);
  } on HttpException {
    checks++;
    return;
  } on FormatException {
    checks++;
    return;
  }
  throw StateError('Malformed cookie batch unexpectedly decoded');
}

void expectNativeRejected(ParsedSetCookieHeaders result) {
  expect(!result.nativePersistenceSupported, 'Ambiguous/unproven native gate closed');
  try {
    final unexpected = result.cookiesForNativePersistence;
    throw StateError('Unsupported representation produced ${unexpected.length} cookies');
  } on UnsupportedSetCookieRepresentation {
    checks++;
    return;
  }
}

Future<void> fixtureChecks() async {
  final input = <String>[
    'id=one; Domain=a.test; Path=/',
    'id=two; Domain=a.test; Path=/x',
    'id=three; Domain=b.test; Path=/',
  ];
  final separate = parse(input, SetCookieSource.separatedFields);
  input[0] = 'mutated=not_part_of_snapshot';
  expect(separate.rawValues.first.startsWith('id=one'), 'Snapshot owns original raw input');
  expect(separate.cookies.map((c) => c.value).join('|') == 'one|two|three', 'Repeated names and scopes retain order');
  expect(separate.cookies.map((c) => c.path).join('|') == '/|/x|/', 'Paths retained');
  expect(separate.cookies.map((c) => c.domain).join('|') == 'a.test|a.test|b.test', 'Domains retained');
  expect(separate.issues.isEmpty && separate.cookiesForNativePersistence.length == 3, 'Separated provenance needs no recovery');
  expect(separate.segments[1].headerIndex == 1 && separate.segments[1].start == 0 &&
      separate.segments[1].end == separate.rawValues[1].length, 'Source ranges retained');
  try { separate.rawValues.add('extra=not_allowed'); }
  on UnsupportedError { checks++; }
  expect(separate.rawValues.length == 3, 'Raw snapshot is immutable');

  const expires = 'a=1; Expires=Wed, 09 Jun 2027 10:18:14 GMT, b=2; Path=/';
  final dated = parse([expires]);
  expect(dated.cookies.map((c) => c.name).join('|') == 'a|b', 'Date comma never becomes a naked segment');
  expect(dated.cookies.first.expires == DateTime.utc(2027, 6, 9, 10, 18, 14), 'Complete Expires date retained');
  expect(dated.segments.first.value == 'a=1; Expires=Wed, 09 Jun 2027 10:18:14 GMT', 'Original date text unchanged');
  expect(dated.segments[1].value == ' b=2; Path=/', 'Recovery does not reserialize cookie text');
  expectNativeRejected(dated);
  final nativeDated = parse([expires], SetCookieSource.foundationCombined);
  expectNativeRejected(nativeDated);
  final separateDated = parse(['a=1; Expires=Wed, 09 Jun 2027 10:18:14 GMT', 'b=2; Path=/'], SetCookieSource.separatedFields);
  expect(separateDated.cookiesForNativePersistence.length == 2, 'Actual separated date fields supported');
  for (final value in ['a=1,b=2', 'a=1, \tb \t= 2']) {
    final recovered = parse([value]);
    expect(recovered.cookies.map((c) => c.name).join('|') == 'a|b', 'Legacy compact/whitespace fold supported');
    expect(recovered.issues.where((i) => i.kind == SetCookieIssueKind.recoveredFold).length == 1, 'Recovery explicitly diagnosed');
    final native = parse([value], SetCookieSource.foundationCombined);
    expect(native.cookiesForNativePersistence.length == 2, 'Pair-only comma cannot belong to a valid cookie value');
  }

  const literalPath = 'a=1; Path=/p, b=2';
  final literal = parse([literalPath], SetCookieSource.separatedFields);
  expect(literal.cookies.length == 1 && literal.cookies.single.path == '/p, b=2', 'Separated Path comma is literal');
  for (final field in [literalPath, 'a=1; X=v, b=2', 'a=1; Secure, b=2',
                       'a=1; Expires=Wed, 09 Jun 2027 10:18:14 GMT, b=2']) {
    final combined = parse([field], SetCookieSource.foundationCombined);
    expect(combined.issues.any((i) => i.kind == SetCookieIssueKind.ambiguousBoundary), 'Attribute boundary marked ambiguous');
    expectNativeRejected(combined);
    expect(parse([field]).cookies.length == 2, 'Dio keeps legacy folded recovery');
  }
  final quotedPath = parse(['a=1; Path="/p, b=2"'], SetCookieSource.separatedFields);
  expect(quotedPath.cookies.single.path == '"/p, b=2"', 'Attribute quotes are literal');
  for (final field in ['a=1; Path="/p, b=2"', 'a=1; X="v, b=2"']) {
    final inspection = parse([field], SetCookieSource.foundationCombined);
    expect(inspection.rawValues.single == field && inspection.segments.length == 2,
        'Ambiguous speculative recovery retains raw input and ranges');
    expect(!inspection.cookiesDecoded && inspection.cookies.isEmpty, 'Ambiguous speculation is not a decoded Cookie batch');
    expectNativeRejected(inspection);
  }
  final quotedPair = parse(['a="ok"; Path=/']);
  expect(quotedPair.cookies.single.value == '"ok"', 'SDK keeps cookie-value quotes');
  expect(parse(['', 'a=1']).cookies.length == 1, 'Empty field compatibility');
  expect(parse([]).cookies.isEmpty, 'No response cookies is empty');
  expect(parse(['a=; Path=/']).cookies.single.value.isEmpty, 'SDK empty cookie value with attribute');
  for (final field in ['a="bad, b=2"', 'a="unterminated, b=2', 'a=1; Expires=bad',
                       'a=1; Max-Age=nope', 'a=1; Secure=yes', 'a=1; HttpOnly=yes',
                       'a=1; SameSite=invalid', 'missingEquals', '=noName', 'a=']) {
    expectMalformed([field]);
  }
  expectMalformed(['valid=one; Path=/', 'broken=two; Max-Age=nope']);

  final jar = DefaultCookieJar();
  final uri = Uri.parse('https://a.test/x/video');
  final identity = parse(['id=old; Path=/; Domain=a.test', 'id=path; Path=/x; Domain=a.test',
                         'id=new; Path=/; Domain=a.test'], SetCookieSource.separatedFields);
  expect(identity.cookies.length == 3, 'Same identity entries not deduplicated by parser');
  await jar.saveFromResponse(uri, identity.cookies);
  final loaded = await jar.loadForRequest(uri);
  expect(loaded.where((c) => c.name == 'id').length == 2, 'Actual CookieJar retains distinct paths');
  expect(loaded.singleWhere((c) => c.path == '/').value == 'new', 'Actual CookieJar applies same-identity last write');
  expect(loaded.singleWhere((c) => c.path == '/x').value == 'path', 'Actual CookieJar preserves path-specific value');
}

List<Map<String, Object?>> wireChecks(String path) {
  final report = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  expect(report['status'] == 'passed', 'Darwin wire observation succeeded');
  final results = <Map<String, Object?>>[];
  for (final observation in report['observations'] as List<dynamic>) {
    final row = observation as Map<String, dynamic>;
    final wire = List<String>.from(row['wireValues'] as List<dynamic>);
    final foundation = List<String>.from(row['foundationValues'] as List<dynamic>);
    final wireParsed = parse(wire, SetCookieSource.separatedFields);
    expect(wireParsed.cookies.length == wire.length, 'Wire field count retained by separated parser');
    final legacy = parse(foundation);
    final native = parse(foundation, SetCookieSource.foundationCombined);
    expect(native.rawValues.join('|') == foundation.join('|'), 'Foundation snapshot retains observed values');
    final semanticParity = native.cookiesDecoded &&
        jsonEncode(native.cookies.map(cookieSemantics).toList()) == jsonEncode(wireParsed.cookies.map(cookieSemantics).toList());
    if (native.nativePersistenceSupported) {
      expect(semanticParity, 'Supported native representation retains ordered wire semantics');
    }
    if (!native.nativePersistenceSupported) expectNativeRejected(native);
    results.add({'id': row['id'], 'wireCookieCount': wireParsed.cookies.length,
      'dioRecoveryCount': legacy.cookies.length,
      'dioOrderedSemanticParity': jsonEncode(legacy.cookies.map(cookieSemantics).toList()) == jsonEncode(wireParsed.cookies.map(cookieSemantics).toList()),
      'nativeRepresentationSupported': native.nativePersistenceSupported,
      'nativeCookiesDecoded': native.cookiesDecoded,
      'nativeOrderedSemanticParity': semanticParity,
      'ambiguousBoundaries': native.issues.where((i) => i.kind == SetCookieIssueKind.ambiguousBoundary).length});
  }
  expect(results.isNotEmpty, 'Wire fixtures were actually exercised');
  return results;
}

Map<String, Object?> cookieSemantics(Cookie cookie) => {
  'name': cookie.name, 'value': cookie.value, 'domain': cookie.domain, 'path': cookie.path,
  'expires': cookie.expires?.toUtc().toIso8601String(), 'maxAge': cookie.maxAge,
  'secure': cookie.secure, 'httpOnly': cookie.httpOnly, 'sameSite': cookie.sameSite?.name,
};

Future<void> main(List<String> arguments) async {
  await fixtureChecks();
  final wire = arguments.isEmpty ? <Map<String, Object?>>[] : wireChecks(arguments.single);
  final output = Directory('build/response-cookie-check')..createSync(recursive: true);
  File('${output.path}/summary.json').writeAsStringSync('${jsonEncode({
    'status': 'passed', 'checks': checks, 'dartVersion': Platform.version,
    'nativeAccountCompatibilityVerified': false, 'wire': wire,
  })}\n');
  stdout.writeln('$checks response Cookie checks passed');
}
