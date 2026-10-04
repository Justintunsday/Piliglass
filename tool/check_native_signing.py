"""Run actual Dart signer/cache producers, then compile production Swift 6."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'build/native-signing-check'
SOURCES = [
    'ios/Runner/Native/Networking/Auth/PiliNativeSigner.swift',
    'ios/Runner/Native/Networking/Auth/PiliWBIKeyProvider.swift',
    'tool/check_native_signing.swift',
]
DART_SOURCES = [
    'lib/utils/wbi_sign.dart', 'lib/utils/app_sign.dart',
    'test/utils/native_signing_golden_test.dart',
    'test/utils/native_wbi_key_cache_test.dart',
    'tool/native_app_signing_release_golden.dart',
]


def run(command, log, timeout):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    output = result.stdout + result.stderr
    (OUTPUT / log).write_text(shlex.join(command) + '\n' + output, encoding='utf-8')
    print(output, end='')
    if result.returncode:
        raise RuntimeError(f'{log} failed with exit {result.returncode}')
    return output


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = dict(status='failed', platform=sys.platform, runtime_cutover=False,
                   source='actual Dart WbiSign/AppSign/Hive cache')
    try:
        if sys.platform != 'darwin':
            raise RuntimeError('macOS Swift required; local static checks cannot verify this contract')
        names = ['dart-golden.json', 'dart-release-golden.json',
                 'dart-mixin-surrogates.json', 'dart-legacy-cache.json']
        for name in names:
            (OUTPUT / name).unlink(missing_ok=True)
        run(['dart', 'analyze', '--fatal-infos', *DART_SOURCES], 'analyze.log', 180)
        run(['flutter', 'test', '--no-pub', '--reporter', 'expanded',
             'test/utils/native_signing_golden_test.dart',
             'test/utils/native_wbi_key_cache_test.dart'], 'dart-fixtures.log', 180)
        run(['dart', 'run', 'tool/native_app_signing_release_golden.dart'], 'dart-release.log', 120)
        for name in names:
            if not (OUTPUT / name).is_file():
                raise RuntimeError(f'Actual Dart evidence missing: {name}')
        executable = OUTPUT / 'check-native-signing'
        run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete',
             '-parse-as-library', '-o', str(executable),
             *(str(ROOT / source) for source in SOURCES)], 'compile.log', 120)
        output = run([str(executable), *(str(OUTPUT / name) for name in names[:3])], 'result.log', 45)
        match = re.search(r'(\d+) native signing and key-cache checks passed', output)
        if not match:
            raise RuntimeError('Swift signing summary missing')
        legacy = json.loads((OUTPUT / 'dart-legacy-cache.json').read_text(encoding='utf-8'))
        summary.update(status='passed', checks=int(match[1]), dart_signing_cases=19,
                       actual_legacy_cache_cases=len(legacy['records']))
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        summary['reason'] = str(error)
        print(f'FAIL native signing: {error}')
    (OUTPUT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    return 0 if summary['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
