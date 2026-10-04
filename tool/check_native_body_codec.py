"""Compare independent native compression/UTF8 with the actual Dart pipeline."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'build/native-body-codec-check'
PACKAGE = ROOT / 'Packages/PiliHTTPBodyCodec'


def run(command, log, timeout, env=None):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                            timeout=timeout, env=env)
    output = result.stdout + result.stderr
    (OUTPUT / log).write_text(shlex.join(command) + '\n' + output, encoding='utf-8')
    print(output, end='')
    if result.returncode:
        raise RuntimeError(f'{log} failed with exit {result.returncode}')
    return output


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = dict(status='failed', platform=sys.platform, runtime_cutover=False,
                   source='actual Request decoder/Dio + actual Dart UTF8')
    try:
        if sys.platform != 'darwin':
            raise RuntimeError('macOS Swift required; local static checks are not compilation evidence')
        for name in ['dart-body-golden.json', 'dart-utf8-golden.json']:
            (OUTPUT / name).unlink(missing_ok=True)
        run(['dart', 'analyze', '--fatal-infos', 'test/http/native_body_codec_golden_test.dart'], 'analyze.log', 180)
        run(['flutter', 'test', '--no-pub', '--reporter', 'expanded',
             'test/http/native_body_codec_golden_test.dart'], 'dart-fixtures.log', 180)
        env = os.environ.copy()
        env['PILIGLASS_BODY_GOLDEN_DIRECTORY'] = str(OUTPUT)
        output = run(['swift', 'test', '--package-path', str(PACKAGE),
                      '-Xswiftc', '-strict-concurrency=complete'], 'swift-test.log', 600, env)
        body = re.search(r'(\d+) actual Dart compressed-body cases passed', output)
        utf8 = re.search(r'(\d+) actual Dart UTF8 cases passed', output)
        if not body or not utf8:
            raise RuntimeError('Actual Dart-to-native decoder evidence missing')
        summary.update(status='passed', body_cases=int(body[1]), utf8_cases=int(utf8[1]),
                       native_package_tests=4)
        resolved = PACKAGE / 'Package.resolved'
        if resolved.exists(): shutil.copy2(resolved, OUTPUT / 'Package.resolved')
        for destination, label in [('generic/platform=iOS', 'device'), ('generic/platform=iOS Simulator', 'simulator')]:
            command = ['xcodebuild', '-scheme', 'PiliHTTPBodyCodec', '-destination', destination,
                       '-derivedDataPath', str(OUTPUT / 'DerivedData'), 'IPHONEOS_DEPLOYMENT_TARGET=16.0',
                       'CODE_SIGNING_ALLOWED=NO', 'build']
            result = subprocess.run(command, cwd=PACKAGE, capture_output=True, text=True, timeout=1200)
            (OUTPUT / (label + '-build.log')).write_text(shlex.join(command) + '\n' + result.stdout + result.stderr, encoding='utf-8')
            if result.returncode:
                print((result.stdout + result.stderr)[-12000:])
                raise RuntimeError(label + ' iOS16 body codec build failed')
        summary.update(ios16Device=True, ios16Simulator=True)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        summary['status'] = 'failed'
        summary['reason'] = str(error)
        print(f'FAIL native body codec: {error}')
    (OUTPUT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    return 0 if summary['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
