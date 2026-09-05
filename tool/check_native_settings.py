"""Exercise the production native settings allowlist and setter without Flutter."""
import argparse
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
STUBS = r'''
void unawaited(Future<void>? future) {}
class NativeCDNMeasurement {
  final String host;
  final double? megabytesPerSecond;
  final String status;
  final String? message;
  const NativeCDNMeasurement(
    this.host,
    this.megabytesPerSecond,
    this.status, {
    this.message,
  });
}
class Box {
  final values = <String, dynamic>{};
  Future<void> put(String? key, dynamic value) async { values[key!] = value; }
}
class GStorage { static final setting = Box(); }
class Home {
  bool enableSaveLastData = true;
  bool personalizedRcmd = true;
  DateTime? lastRefreshAt = DateTime(2026);
  Future<void> onRefresh() async {}
  Future<void> setPersonalizedRecommendations(bool value) async {
    personalizedRcmd = value;
  }
}
class Main { bool checkDynamic = true; }
class VideoUtils { static bool disableAudioCDN = false; }
class Bridge {
  final _homeController = Home();
  final mainController = Main();
  Map<String, dynamic> _nativeSettingsSnapshot() => {'state': 'success'};
  // PRODUCTION
}
int checks = 0;
void expect(bool condition, String message) {
  checks++;
  if (!condition) throw StateError(message);
}
Future<void> main() async {
  final bridge = Bridge();
  Future<Map<String, dynamic>> save(dynamic key, dynamic value) =>
      bridge._setNativeSetting({'key': key, 'value': value});
  for (final definition in Bridge._nativeSettingDefinitions) {
    final key = definition['key'] as String;
    expect((await save(key, false))['state'] == 'success' && GStorage.setting.values[key] == false,
      '$key must persist false');
    expect((await save(key, true))['state'] == 'success' && GStorage.setting.values[key] == true,
      '$key must persist true');
  }
  final before = Map.of(GStorage.setting.values);
  for (final key in ['enableQuickDouble', 'enableHA', 'autoPlayEnable', 'showFsScreenshotBtn',
      'showSeekPreview', 'showDmChart', 'enableOnlineTotal', 'tempPlayerConf', 'danmakuStrokeWidth', 'unknown']) {
    expect((await save(key, true))['state'] == 'error' && !GStorage.setting.values.containsKey(key),
      'obsolete or unsupported setting $key must not be writable');
  }
  for (final value in [null, 'true', 1, [], {}]) {
    expect((await save(SettingBoxKey.disableAudioCDN, value))['state'] == 'error',
      'reject non-boolean value $value');
  }
  expect(before.length == GStorage.setting.values.length, 'invalid inputs cannot create settings');
  await save(SettingBoxKey.enableSaveLastData, false);
  expect(!bridge._homeController.enableSaveLastData && bridge._homeController.lastRefreshAt == null,
    'recommendation setting must immediately update the active controller');
  await save(SettingBoxKey.checkDynamic, false);
  expect(!bridge.mainController.checkDynamic, 'unread check must immediately update the active controller');
  await save(SettingBoxKey.disableAudioCDN, false);
  expect(!VideoUtils.disableAudioCDN, 'audio CDN selection must update the playback URL resolver');
  await save(SettingBoxKey.personalizedRcmd, false);
  expect(!bridge._homeController.personalizedRcmd,
    'personalized recommendation setting must update the active feed controller');
  print('$checks native settings checks passed');
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dart', default='dart')
    args = parser.parse_args()
    source = (ROOT / 'lib/services/ios_native_ui_bridge.dart').read_text(encoding='utf-8')
    definitions = source[source.index('  static const List<Map<String, dynamic>> _nativeSettingDefinitions'):
                         source.index('  Map<String, dynamic> _nativeSettingsSnapshot()')]
    setter = source[source.index('  Future<Map<String, dynamic>> _setNativeSetting('):
                    source.index('  Future<Map<String, dynamic>> _setNativeVideoQuality(')]
    output = ROOT / 'build/native-settings-check'
    output.mkdir(parents=True, exist_ok=True)
    keys = (ROOT / 'lib/utils/storage_key.dart').read_text(encoding='utf-8')
    (output / 'check.dart').write_text(keys + STUBS.replace('// PRODUCTION', definitions + setter), encoding='utf-8')
    (output / 'pubspec.yaml').write_text('name: native_settings_check\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\n')
    (output / 'analysis_options.yaml').write_text('{}\n')
    env = dict(os.environ, PUB_CACHE=str(output / 'pub-cache'))
    if os.name == 'nt':
        env['APPDATA'] = str(output / 'config')
    for command in [['analyze', 'check.dart'], ['run', 'check.dart']]:
        subprocess.run([args.dart, *command], cwd=output, env=env, check=True)


if __name__ == '__main__':
    main()
