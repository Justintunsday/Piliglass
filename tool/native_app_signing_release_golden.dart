import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/utils/app_sign.dart';

/// Plain Dart imports the actual pure AppSign source. Run without
/// --enable-asserts to record its existing release null behavior separately.
void main() {
  var assertionsEnabled = false;
  assert(() { assertionsEnabled = true; return true; }());
  if (assertionsEnabled) throw StateError('Release fixture requires disabled asserts');
  const epoch = 1735689601;
  const key = 'fixture-app-key';
  const secret = 'fixture-app-secret';
  final params = <String, dynamic>{'nil': null, 'empty': '', 'sign': 'old'};
  final query = AppSign.makeSigningQuery({...params, 'appkey': key, 'ts': '$epoch'});
  final input = _fields(params);
  AppSign.appSign(params, appkey: key, appsec: secret, epochSeconds: epoch);
  final file = File('build/native-signing-check/dart-release-golden.json');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'source': 'actual AppSign.appSign with Dart assertions disabled',
    'assertionsEnabled': false,
    'records': [{'name': 'app-release-null', 'kind': 'app', 'input': input,
      'appKey': key, 'appSecret': secret, 'epochSeconds': '$epoch', 'query': query,
      'digest': params['sign'], 'output': _fields(params), 'allowReleaseNullValues': true}],
  }));
  stdout.writeln('Actual Dart release AppSign golden written');
}

List<Map<String, Object?>> _fields(Map<String, dynamic> params) => [
  for (final entry in params.entries)
    {'key': entry.key, 'type': entry.value == null ? 'null' : 'string', 'value': entry.value},
];
