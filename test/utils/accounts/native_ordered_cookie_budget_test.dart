import 'package:PiliPlus/services/native_accounts/native_ordered_cookie_jar_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('streamed wire counting includes the actual JSON framing bytes', () {
    const limit = NativeOrderedCookieJarExporter.maxWireBytes;
    // Isolated encoder/sink boundary, independent of the source-tree unit cap.
    // The real encoder contributes quotes, the key and object framing bytes.
    NativeOrderedCookieJarExporter.verifyWireCapacity({'wire': 's' * (limit - 20)});
    expect(
      () => NativeOrderedCookieJarExporter.verifyWireCapacity({'wire': 's' * limit}),
      throwsA(isA<NativeOrderedCookieJarExportException>().having(
        (e) => e.code, 'code', 'wireCapacityExceeded')),
    );
  });
}
