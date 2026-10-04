import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

class _BodyAdapter implements HttpClientAdapter {
  List<int> bytes = const [];
  Map<String, List<String>> headers = const {};
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelled) => Future.value(ResponseBody.fromBytes(bytes, 200,
        headers: headers));
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory directory;
  final adapter = _BodyAdapter();
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    directory = await Directory.systemTemp.createTemp('piliglass-body-codec-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox<dynamic>('setting');
    await GStorage.setting.putAll({SettingBoxKey.enableHttp2: false, SettingBoxKey.retryCount: 0});
    Request();
    Request.dio.httpClientAdapter.close(force: true);
    Request.dio.httpClientAdapter = adapter;
    Request.dio.interceptors.clear();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('actual Request body decoder and Dio UTF8 path export native golden', () async {
    final text = utf8.encode('中文🙂 hello');
    final gzip = const GZipEncoder().encodeBytes(text);
    final gzip2 = const GZipEncoder().encodeBytes(utf8.encode(' second'));
    final zlib = const ZLibEncoder().encodeBytes(text);
    final badCRC = [...gzip];
    badCRC[badCRC.length - 8] ^= 1;
    final brotli = base64Decode('CwKAaGVsbG8D'); // Node zlib.BrotliCompress("hello")
    final cases = <(String, List<int>, Map<String, List<String>>)>[
      ('raw', text, {}),
      ('gzip', gzip, {'content-encoding': ['gzip']}),
      ('gzip-concatenated', [...gzip, ...gzip2], {'content-encoding': ['gzip']}),
      ('gzip-zlib-envelope', zlib, {'content-encoding': ['gzip']}),
      ('gzip-incomplete-trailer', gzip.sublist(0, gzip.length - 7), {'content-encoding': ['gzip']}),
      ('gzip-incomplete-member', gzip.sublist(0, 14), {'content-encoding': ['gzip']}),
      ('gzip-empty-input', [], {'content-encoding': ['gzip']}),
      ('gzip-bad-crc', badCRC, {'content-encoding': ['gzip']}),
      ('gzip-trailing-garbage', [...gzip, 255, 255], {'content-encoding': ['gzip']}),
      ('br', brotli, {'content-encoding': ['br']}),
      ('br-unicode', base64Decode('iwSA5Lit5paH8J+ZggM='), {'content-encoding': ['br']}),
      ('br-empty-output', base64Decode('Ow=='), {'content-encoding': ['br']}),
      ('br-empty-input', [], {'content-encoding': ['br']}),
      ('br-truncated', brotli.sublist(0, brotli.length - 2), {'content-encoding': ['br']}),
      ('br-unused-bytes', [...brotli, 255], {'content-encoding': ['br']}),
      ('br-large-output', base64Decode('W5+GgV8iLB4LBLL8AgA='), {'content-encoding': ['br']}),
      ('case-sensitive-token', gzip, {'content-encoding': ['GZip']}),
      ('stacked-token', gzip, {'content-encoding': ['gzip, br']}),
      ('unknown-token', text, {'content-encoding': ['deflate']}),
      ('case-sensitive-map-key', gzip, {'Content-Encoding': ['gzip']}),
      ('first-value-only', gzip, {'content-encoding': ['gzip', 'br']}),
      ('empty-header-values', text, {'content-encoding': []}),
      ('bom', [239, 187, 191, ...text], {}),
      ('two-boms', [239, 187, 191, 239, 187, 191, ...text], {}),
      ('malformed-utf8', [240, 159, 65, 237, 160, 128, 192, 128], {}),
    ];
    final records = <Map<String, Object?>>[];
    for (final (name, bytes, headers) in cases) {
      final record = <String, Object?>{'name': name, 'input': base64Encode(bytes), 'headers': headers};
      List<int>? decoded;
      try {
        decoded = Request.responseBytesDecoder(bytes, headers);
        record['decoded'] = base64Encode(decoded);
        record['utf16'] = utf8.decode(decoded, allowMalformed: true).codeUnits;
      } catch (_) {
        record['error'] = true;
      }
      // Normalized-header cases also exercise the actual private production
      // responseDecoder via real Dio transformation, not another test parser.
      if (decoded != null && !headers.containsKey('Content-Encoding')) {
        adapter
          ..bytes = bytes
          ..headers = headers;
        final response = await Request.dio.get<String>('/fixture',
          options: Options(responseType: ResponseType.plain));
        expect(response.data!.codeUnits, record['utf16'], reason: name);
        record['actualDioDecoder'] = true;
      }
      records.add(record);
    }
    final file = File('build/native-body-codec-check/dart-body-golden.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({
      'source': 'actual Request.responseBytesDecoder + actual Dio production responseDecoder',
      'records': records,
    }));
    expect(records.where((record) => record['actualDioDecoder'] == true).length, greaterThan(12));
    expect(records.first['decoded'], base64Encode(text));
    expect(records.singleWhere((record) => record['name'] == 'br')['decoded'], base64Encode(utf8.encode('hello')));
  });

  test('actual Dart UTF8 allowMalformed corpus includes all bytes and byte pairs', () async {
    final records = <Map<String, Object>>[];
    void record(List<int> bytes) => records.add({
      'bytes': bytes, 'utf16': utf8.decode(bytes, allowMalformed: true).codeUnits,
    });
    record([]);
    for (var a = 0; a < 256; a++) {
      record([a]);
      for (var b = 0; b < 256; b++) { record([a, b]); }
    }
    for (final bytes in <List<int>>[
      [239, 187, 191], [239, 187, 191, 239, 187, 191], [65, 239, 187, 191],
      [224, 160], [224, 159, 128], [237, 160, 128], [240, 144],
      [240, 159, 153], [244, 143, 191, 191], [244, 144, 128, 128],
      [245, 128, 128, 128], [226, 130, 65], [240, 159, 65, 128],
    ]) { record(bytes); }
    final random = Random(0x50494C49);
    for (var index = 0; index < 2048; index++) {
      record(List.generate(3 + index % 10, (_) => random.nextInt(256)));
    }
    final file = File('build/native-body-codec-check/dart-utf8-golden.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'source': 'actual Dart utf8.decode allowMalformed:true', 'records': records}));
    expect(records, hasLength(67854));
  });
}
