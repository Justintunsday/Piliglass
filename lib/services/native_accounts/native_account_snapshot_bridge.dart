import 'package:PiliPlus/services/native_accounts/native_account_snapshot_service.dart';

final class NativeAccountSnapshotBridge {
  NativeAccountSnapshotBridge(this.service);
  final NativeAccountSnapshotService service;

  Future<Map<String, Object?>> handle(String method, Object? arguments) async {
    if (arguments != null && (arguments is! Map || arguments.isNotEmpty)) {
      return _error('invalidArguments');
    }
    try {
      return switch (method) {
        'loadNativeAccountSelection' => await service.selectionSnapshot(),
        'exportNativeAccountStaging' => await service.stagingExport(),
        _ => _error('unknownCommand'),
      };
    } on NativeAccountSnapshotException catch (error) {
      return _error(error.code);
    } catch (_) {
      return _error('captureFailed');
    }
  }

  static Map<String, Object?> _error(String code) => {
    'state': 'error', 'code': code, 'nativeWritesAllowed': false,
  };
}
