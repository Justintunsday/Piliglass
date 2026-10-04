"""Compile production policy routing and head-time lease execution under Swift 6."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'build/native-http-execution-check'
SOURCES = [
    'ios/Runner/Native/Networking/HTTP/PiliPreparedHTTPPolicy.swift',
    'ios/Runner/Native/Networking/HTTP/PiliHTTPPolicyCapability.swift',
    'ios/Runner/Native/Networking/HTTP/PiliHTTPClient.swift',
    'ios/Runner/Native/Domain/Accounts/PiliHTTPRequestContext.swift',
    'ios/Runner/Native/Data/Accounts/PiliHTTPRequestHeaderFinalizer.swift',
    'ios/Runner/Native/Data/HTTP/PiliPreparedHTTPRequestExecutor.swift',
    'tool/check_native_http_execution.swift',
]


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = dict(status='failed', platform=sys.platform)
    try:
        if sys.platform != 'darwin':
            raise RuntimeError('macOS Swift required; compilation not verified')
        executable = OUTPUT / 'check-native-http-execution'
        command = ['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete',
                   '-D', 'PILI_HTTP_FIXTURES', '-parse-as-library', '-o', str(executable),
                   *(str(ROOT / source) for source in SOURCES)]
        compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
        (OUTPUT / 'compile.log').write_text(shlex.join(command) + '\n' + compiled.stdout + compiled.stderr, encoding='utf-8')
        if compiled.returncode:
            print(compiled.stdout + compiled.stderr, end='')
            raise RuntimeError('Production Swift compile failed')
        result = subprocess.run([str(executable)], cwd=ROOT, capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        (OUTPUT / 'result.log').write_text(output, encoding='utf-8')
        print(output, end='')
        match = re.search(r'(\d+) native HTTP execution checks passed', output)
        if result.returncode or not match:
            raise RuntimeError('Production HTTP execution contract failed')
        summary.update(status='passed', checks=int(match[1]), evidence='synthetic lifecycle only; runtime gates closed')
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        summary['reason'] = str(error)
        print(f'FAIL native HTTP execution: {error}')
    (OUTPUT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    return 0 if summary['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
