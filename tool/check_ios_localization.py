"""Validate iOS translations; on macOS also exercise Foundation resource lookup.

Run with Python 3. No third-party Python packages are required.
"""
import json
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "ios/Runner"
ENTRY = re.compile(r'"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;')
FORMAT = re.compile(r'%(?:\d+\$)?[-+0 #]*\d*(?:\.\d+)?(?:ll|l|z)?[@diufgse%]')


def catalog(path):
    source = path.read_text(encoding="utf-8")
    source = re.sub(r'/\*.*?\*/', '', source, flags=re.S)
    values = {}
    for match in ENTRY.finditer(source):
        key, value = (json.loads('"' + part + '"') for part in match.groups())
        assert key not in values, f"Duplicate key in {path}: {key}"
        assert value, f"Empty translation in {path}: {key}"
        assert '\\(' not in key + value, f"Raw Swift interpolation: {key}"
        assert FORMAT.findall(key) == FORMAT.findall(value), f"Format mismatch: {key}"
        values[key] = value
    assert not ENTRY.sub('', source).strip(), f"Malformed strings file: {path}"
    return values


def check_sources(english):
    # Every literal SwiftUI UI label and explicit localization lookup must
    # resolve. Internal routing strings and authored content are not UI keys.
    calls = re.compile(
        r'(?:piliLocalized(?:Format)?|Text|Button|Label|Toggle|Picker|Section|'
        r'TextField|ProgressView|navigationTitle|navigationBarTitle|'
        r'accessibilityLabel|alert|confirmationDialog)\(\s*"((?:\\.|[^"\\])*)"'
    )
    sources = list(RUNNER.glob('*.swift')) + [ROOT / 'ios/SwiftgramUI/Sources/SwiftgramMessagingUI.swift']
    for path in sources:
        for raw in calls.findall(path.read_text(encoding='utf-8')):
            if not re.search('[\u4e00-\u9fff]', raw) or '\\(' in raw:
                continue
            key = json.loads('"' + raw + '"')
            assert key in english, f"Missing English UI string in {path.name}: {key}"


def check_foundation():
    if platform.system() != 'Darwin':
        print('SKIP Foundation runtime checks: macOS/Xcode required')
        return
    for locale in ['en', 'zh-Hans']:
        for name in ['Localizable.strings', 'InfoPlist.strings']:
            subprocess.run(['plutil', '-lint', str(RUNNER / f'{locale}.lproj' / name)], check=True)
    with tempfile.TemporaryDirectory(prefix='piliglass-localization-') as temp:
        base = Path(temp)
        bundle = base / 'Localization.bundle'
        bundle.mkdir()
        for locale in ['en', 'zh-Hans']:
            shutil.copytree(RUNNER / f'{locale}.lproj', bundle / f'{locale}.lproj')
        with (bundle / 'Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleIdentifier': 'dev.piliglass.localization-check',
                          'CFBundleDevelopmentRegion': 'en'}, stream)
        swift = base / 'check.swift'
        program = r'''
import Foundation
let resourcePath = CommandLine.arguments[1]
let english = Bundle(path: resourcePath + "/en.lproj")!
let chinese = Bundle(path: resourcePath + "/zh-Hans.lproj")!
func value(_ bundle: Bundle, _ key: String) -> String {
  bundle.localizedString(forKey: key, value: key, table: "Localizable")
}
assert(value(english, "首页") == "Home")
assert(value(chinese, "首页") == "首页")
assert(value(english, "设置") == "Settings")
assert(value(chinese, "设置") == "设置")
let exampleName = "首页"
assert(String(format: value(english, "回复 %@"), exampleName) == "Reply to 首页")
assert(String(format: value(chinese, "回复 %@"), exampleName) == "回复 首页")
assert(String(format: value(english, "共 %d 个视频"), 12) == "12 videos")
assert(String(format: value(chinese, "共 %d 个视频"), 12) == "共 12 个视频")
assert(value(english, "Untranslated server message") == "Untranslated server message")
let available = ["en", "zh-Hans"]
assert(Bundle.preferredLocalizations(from: available, forPreferences: ["en-GB"]).first == "en")
assert(Bundle.preferredLocalizations(from: available, forPreferences: ["zh-Hans-CN"]).first == "zh-Hans")
assert(Bundle.preferredLocalizations(from: available, forPreferences: ["fr", "en"]).first == "en")
assert(Bundle.preferredLocalizations(from: available, forPreferences: ["fr", "zh-Hans"]).first == "zh-Hans")
print("PASS Foundation English/Chinese lookup, interpolation and language preferences")
'''
        # Run the production count formatter at boundaries where Chinese and
        # English scales differ (10,000 is 1万 but 10K, 100M is 1亿).
        native = (RUNNER / 'PiliNativeRootViewController.swift').read_text(encoding='utf-8')
        formatter = native[native.index('private func piliCompactNumber('):]
        program += '''
var englishNumbers = true
func piliNativeIsEnglish() -> Bool { englishNumbers }
''' + formatter + '''
assert(piliCompactNumber(999) == "999")
assert(piliCompactNumber(1_000) == "1.0K")
assert(piliCompactNumber(10_000) == "10.0K")
assert(piliCompactNumber(1_000_000) == "1.0M")
assert(piliCompactNumber(100_000_000) == "100.0M")
assert(piliCompactNumber(1_000_000_000) == "1.0B")
englishNumbers = false
assert(piliCompactNumber(1_000) == "1000")
assert(piliCompactNumber(10_000) == "1.0万")
assert(piliCompactNumber(100_000_000) == "1.0亿")
print("PASS production English/Chinese number formatting")
'''
        swift.write_text(program, encoding='utf-8')
        subprocess.run(['xcrun', 'swift', str(swift), str(bundle)], check=True)


def main():
    english = catalog(RUNNER / 'en.lproj/Localizable.strings')
    chinese = catalog(RUNNER / 'zh-Hans.lproj/Localizable.strings')
    assert english.keys() == chinese.keys(), 'English/Chinese keys differ'
    assert all(k == v for k, v in chinese.items()), 'Chinese source copy changed'
    check_sources(english)
    info = plistlib.loads((RUNNER / 'Info.plist').read_bytes())
    for locale in ['en', 'zh-Hans']:
        permissions = catalog(RUNNER / f'{locale}.lproj/InfoPlist.strings')
        assert all(k in permissions for k in info if k.startswith('NS') and k.endswith('UsageDescription'))
    project = (ROOT / 'ios/Runner.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
    for locale in ['en', 'zh-Hans']:
        for name in ['Localizable.strings', 'InfoPlist.strings']:
            assert f'{locale}.lproj/{name}' in project, f'Missing resource registration: {locale}/{name}'
    assert 'PiliNativeLocalization.swift in Sources' in project
    # Exercise source generators here too: they run on Windows without Xcode.
    import preview_ios_navigation
    import check_ios_account_pages
    import check_ios_image_preview
    import check_ios_player_controls
    for module in [preview_ios_navigation, check_ios_account_pages, check_ios_image_preview,
                   check_ios_player_controls]:
        source = module.production_swift()
        assert source.count('func piliLocalized(_ key: String)') == 1, module.__name__
    print(f'PASS {len(english)} bilingual keys, formats, UI coverage, permissions, project resources and 4 preview generators')
    check_foundation()


if __name__ == '__main__':
    main()
