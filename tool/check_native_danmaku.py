"""Run the production native settings service without Flutter or real accounts.

Only HTTP, account and Hive boundaries are replaced with in-memory fakes. The
service, rule model and matcher are copied verbatim (imports are redirected).
Requires Python 3 and Dart; uses an isolated pub cache/config under build/.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]

STUBS = r'''
class FakeBox {
  final values = <String, dynamic>{};
  dynamic get(String key, {dynamic defaultValue}) => values[key] ?? defaultValue;
  bool containsKey(String key) => values.containsKey(key);
  Future<void> put(String key, dynamic value) async { values[key] = value; }
  Future<void> putAll(Map<String, dynamic> value) async { values.addAll(value); }
}
class GStorage {
  static final localCache = FakeBox();
  static final setting = FakeBox();
}
class Account { bool isLogin = false; int mid = 0; }
class Accounts { static final main = Account(); }
class Pref {
  static RuleFilter get danmakuFilterRule => GStorage.localCache.get(LocalCacheKey.danmakuFilterRules, defaultValue: RuleFilter.empty());
  static Set<int> get danmakuBlockType => Set<int>.from(GStorage.setting.get(SettingBoxKey.danmakuBlockType, defaultValue: <int>[]));
  static int get danmakuWeight => GStorage.setting.get(SettingBoxKey.danmakuWeight, defaultValue: 0);
  static double get danmakuShowArea => GStorage.setting.get(SettingBoxKey.danmakuShowArea, defaultValue: 0.5);
  static double get danmakuOpacity => GStorage.setting.get(SettingBoxKey.danmakuOpacity, defaultValue: 1.0);
  static double get danmakuFontScale => GStorage.setting.get(SettingBoxKey.danmakuFontScale, defaultValue: 1.0);
  static double get danmakuDuration => GStorage.setting.get(SettingBoxKey.danmakuDuration, defaultValue: 7.0);
  static double get danmakuStrokeWidth => GStorage.setting.get(SettingBoxKey.danmakuStrokeWidth, defaultValue: 1.5);
}
class DanmakuElem {
  final String content, midHash;
  DanmakuElem(this.content, [this.midHash = '']);
}
sealed class LoadingState<T> {
  bool get isSuccess => this is Success<T>;
}
class Success<T> extends LoadingState<T> {
  final T response;
  Success(this.response);
}
class Error extends LoadingState<Never> {
  @override String toString() => 'offline';
}
class DanmakuFilterHttp {
  static bool failLoad = false, failAdd = false, failDelete = false;
  static final calls = <String>[];
  static final remote = <Map<String, dynamic>>[];
  static int nextId = 100;
  static Future<LoadingState<DanmakuBlockDataModel>> danmakuFilter() async {
    calls.add('load');
    return failLoad ? Error() : Success(DanmakuBlockDataModel.fromJson({'rule': remote}));
  }
  static Future<LoadingState<SimpleRule>> danmakuFilterAdd({required String filter, required int type}) async {
    calls.add('add');
    if (failAdd) return Error();
    final rule = <String, dynamic>{'id': nextId++, 'filter': filter, 'type': type};
    remote.add(rule);
    return Success(SimpleRule.fromJson(rule));
  }
  static Future<LoadingState<void>> danmakuFilterDel({required int ids}) async {
    calls.add('delete');
    if (failDelete) return Error();
    remote.removeWhere((e) => e['id'] == ids);
    return Success(null);
  }
}
'''

CHECKS = r'''
int checks = 0;
void expect(bool ok, String name) {
  if (!ok) throw StateError(name);
  checks++;
  print('PASS $name');
}
Future<void> main() async {
  final service = NativeDanmakuSettings();
  Future<Map<String, dynamic>> call(String action, [Map<String, dynamic> args = const {}]) => service.handle({'action': action, 'owner': Accounts.main.isLogin ? '${Accounts.main.mid}' : 'guest', ...args});
  List<dynamic> rows(Map<String, dynamic> snapshot) => snapshot['rules'] as List;
  GStorage.localCache.values[LocalCacheKey.danmakuFilterRules] = RuleFilter(['legacy'], [RegExp('old')], {'abc'});
  var result = await call('load');
  expect(rows(result).length == 3, 'migrate all three legacy rule types');
  expect(rows(await call('load')).length == 3, 'migration is idempotent');
  expect((await call('sync'))['state'] == 'error' && DanmakuFilterHttp.calls.isEmpty, 'guest sync does not call server');
  final id = rows(result).first['id'];
  expect((await call('edit', {'id': id, 'type': 1, 'filter': '['}))['state'] == 'error', 'invalid regex rejected');
  expect(rows(await call('load')).first['filter'] == 'legacy', 'invalid edit preserves old rule');
  expect((await call('add', {'type': 0, 'filter': '   '}))['state'] == 'error', 'empty keyword rejected');
  expect((await call('add', {'type': 1, 'filter': '//'}))['state'] == 'error', 'empty regex rejected');
  expect((await call('add', {'type': 2, 'filter': '你好'}))['state'] == 'error', 'non-numeric UID rejected');
  result = await call('add', {'type': 2, 'filter': '123456789'});
  expect(rows(result).last['filter'] == 'cbf43926', 'UID uses standard CRC32, not plaintext');
  result = await call('add', {'type': 1, 'filter': '/hello.*/'});
  expect(rows(result).last['filter'] == 'hello.*', 'regex delimiters normalized');
  expect(Pref.danmakuFilterRule.remove(DanmakuElem('HELLO WORLD')), 'regex matching ignores case');
  expect((await call('add', {'type': 1, 'filter': 'hello.*'}))['state'] == 'error', 'duplicate rejected');
  result = await call('edit', {'id': id, 'type': 0, 'filter': 'replacement'});
  expect(!rows(result).any((e) => e['filter'] == 'legacy') && rows(result).any((e) => e['filter'] == 'replacement'), 'local edit replaces atomically');
  result = await call('delete', {'id': rows(result).last['id']});
  expect(!rows(result).any((e) => e['filter'] == 'replacement'), 'local delete persists');
  expect((await call('add', {'type': 0, 'filter': 'blocked', 'cloud': true}))['state'] == 'error', 'guest cannot mutate account rules');
  final settings = <String, dynamic>{'blockTypes': [2, 4, 5, 6, 7], 'weight': 11, 'area': 0.75, 'opacity': 0.0, 'fontScale': 1.7, 'duration': 9.0, 'strokeWidth': 0.0};
  result = await call('save', settings);
  expect(result['weight'] == 11 && result['opacity'] == 0.0 && result['fontScale'] == 1.7, 'settings include maximum weight and zero opacity');
  result = await call('save', {...settings, 'opacity': double.nan});
  expect(result['state'] == 'error' && (await call('load'))['opacity'] == 0.0, 'invalid settings do not partially persist');
  Accounts.main..isLogin = true..mid = 42;
  expect(rows(await call('load')).isEmpty, 'guest rules do not leak into account');
  await call('add', {'type': 0, 'filter': 'local'});
  result = await call('add', {'type': 0, 'filter': 'cloud', 'cloud': true});
  final cloudId = rows(result).last['id'];
  DanmakuFilterHttp.failLoad = true;
  expect((await call('sync'))['state'] == 'error' && rows(await call('load')).length == 2, 'failed sync preserves local and cloud rules');
  DanmakuFilterHttp.failLoad = false;
  expect(rows(await call('sync')).length == 2 && rows(await call('sync')).length == 2, 'repeated sync neither duplicates nor erases local rules');
  DanmakuFilterHttp.failAdd = true;
  DanmakuFilterHttp.calls.clear();
  expect((await call('edit', {'id': cloudId, 'type': 0, 'filter': 'edited'}))['state'] == 'error', 'failed cloud edit is reported');
  expect(!DanmakuFilterHttp.calls.contains('delete') && rows(await call('load')).any((e) => e['id'] == cloudId), 'cloud edit adds before deleting original');
  DanmakuFilterHttp.failAdd = false;
  DanmakuFilterHttp.failDelete = true;
  result = await call('edit', {'id': cloudId, 'type': 0, 'filter': 'edited'});
  expect(result['warning'] != null && rows(result).length == 3, 'partial cloud edit retains both rules and exposes warning');
  expect((await call('delete', {'id': cloudId}))['state'] == 'error' && rows(await call('load')).length == 3, 'failed cloud deletion preserves rule');
  DanmakuFilterHttp.failDelete = false;
  expect(rows(await call('delete', {'id': cloudId})).length == 2, 'cloud deletion succeeds on retry');
  Accounts.main.mid = 99;
  expect((await call('add', {'owner': '42', 'type': 0, 'filter': 'stale', 'cloud': true}))['state'] == 'error', 'stale account mutation rejected');
  expect(rows(await call('load')).isEmpty, 'accounts have isolated caches');
  Accounts.main.mid = 42;
  expect(rows(await call('load')).length == 2, 'switching back restores cached rules');
  final batches = await Future.wait(List.generate(8, (i) => call('add', {'type': 0, 'filter': 'serial-$i'})));
  expect(batches.every((e) => e['state'] == 'success') && rows(await call('load')).length == 10, 'concurrent edits do not lose updates');
  final filter = RuleFilter.fromRuleTypeEntries([
    [SimpleRule.fromJson({'id': 1, 'type': 0, 'filter': ''})],
    [SimpleRule.fromJson({'id': 2, 'type': 1, 'filter': '['}), SimpleRule.fromJson({'id': 3, 'type': 1, 'filter': '/test/'})],
    [],
  ]);
  expect(filter.count == 1 && filter.remove(DanmakuElem('TEST')) && !filter.remove(DanmakuElem('unrelated')), 'malformed cached regex and empty keyword cannot break playback');
  print('$checks checks passed');
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dart', default='dart')
    args = parser.parse_args()
    output = ROOT / 'build/native-danmaku-check'
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, PUB_CACHE=str(output / 'pub-cache'))
    if os.name == 'nt':
        env['APPDATA'] = str(output / 'config')
    sources = []
    for name in ['lib/services/native_danmaku_settings.dart', 'lib/models/user/danmaku_block.dart', 'lib/models/user/danmaku_rule.dart']:
        source = (ROOT / name).read_text(encoding='utf-8')
        sources.append(re.sub(r"import .*?;\s*", '', source, flags=re.S))
    keys = (ROOT / 'lib/utils/storage_key.dart').read_text(encoding='utf-8')
    sources.append(keys)
    imports = "import 'dart:convert';\nimport 'package:archive/archive.dart' show getCrc32;\nimport 'package:synchronized/synchronized.dart';\n"
    (output / 'check.dart').write_text(imports + STUBS + '\n'.join(sources) + CHECKS, encoding='utf-8')
    (output / 'pubspec.yaml').write_text('name: native_danmaku_check\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\ndependencies:\n  archive: ^4.0.0\n  synchronized: ^3.3.0\n', encoding='utf-8')
    (output / 'analysis_options.yaml').write_text('{}\n', encoding='utf-8')
    for command in [['pub', 'get'], ['analyze', 'check.dart'], ['run', 'check.dart']]:
        subprocess.run([args.dart, *command], cwd=output, env=env, check=True)


if __name__ == '__main__':
    main()
