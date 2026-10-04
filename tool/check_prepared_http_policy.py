"""Consume actual Dart bridge exports with the production Swift codec/provider."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

from check_native_request_context import SOURCES

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'build/prepared-http-policy'


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = dict(status='failed', source='actual Dart bridge/Hive exports', platform=sys.platform)
    try:
        if sys.platform != 'darwin':
            raise RuntimeError('macOS Swift required; a local skip cannot verify this contract')
        goldens = [OUTPUT / f'{mode}.json' for mode in ['http11', 'http2']]
        for golden in goldens:
            if not golden.is_file():
                raise RuntimeError(f'Actual Dart golden missing: {golden.name}')
        sources = [value for value in SOURCES if value not in
                   ['tool/check_native_request_context.swift', 'tool/prepared_http_policy_fixture.swift']]
        sources.append('tool/check_prepared_http_policy.swift')
        executable = OUTPUT / 'check-prepared-http-policy'
        command = ['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete',
                   '-parse-as-library', '-o', str(executable), *(str(ROOT / source) for source in sources)]
        compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
        (OUTPUT / 'compile.log').write_text(shlex.join(command) + '\n' + compiled.stdout + compiled.stderr, encoding='utf-8')
        if compiled.returncode:
            print(compiled.stdout + compiled.stderr, end='')
            raise RuntimeError('Production Swift compile failed')
        result = subprocess.run([str(executable), *(str(golden) for golden in goldens)], cwd=ROOT,
                                capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        (OUTPUT / 'result.log').write_text(output, encoding='utf-8')
        print(output, end='')
        match = re.search(r'(\d+) prepared HTTP policy checks passed', output)
        if result.returncode or not match:
            raise RuntimeError('Dart-to-Swift policy contract failed')
        summary.update(status='passed', checks=int(match[1]), golden_files=2, golden_cases=16)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        summary['reason'] = str(error)
        print(f'FAIL prepared HTTP policy: {error}')
    (OUTPUT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    return 0 if summary['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
