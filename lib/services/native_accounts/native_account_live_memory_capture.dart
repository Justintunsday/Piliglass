import 'package:PiliPlus/utils/accounts.dart';

/// No storage publication, bridge command, writer freeze or authority switch.
final class NativeAccountLiveMemoryCaptureService {
  NativeAccountLiveMemoryCaptureService({Future<void> Function()? checkpoint})
    : _checkpoint = checkpoint ?? _yield;

  final Future<void> Function() _checkpoint;
  static Future<void> _yield() => Future<void>.value();

  Future<Map<String, Object?>> capture() async {
    final candidate = Accounts.captureLiveMemoryShadow();
    await _checkpoint();
    candidate.verifyCurrent();
    return candidate.value;
  }
}
