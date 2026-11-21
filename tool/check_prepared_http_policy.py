"""Consume actual Dart bridge exports with the production Swift codec/provider."""
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

from check_native_request_context import SOURCES

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'build/prepared-http-policy'
TRENDING_SOURCES = [
    'ios/Runner/Native/Domain/Search/PiliSearchRepository.swift',
    'ios/Runner/Native/Domain/Accounts/PiliAccountRepository.swift',
    'ios/Runner/Native/Persistence/Accounts/PiliAccountSecretStore.swift',
    'ios/Runner/Native/Data/Accounts/PiliAccountSnapshotBridgeCodec.swift',
    'ios/Runner/Native/Data/Accounts/PiliAccountStagingBridgeCodec.swift',
    'ios/Runner/Native/Data/Accounts/PiliAccountFlutterRepository.swift',
    'ios/Runner/Native/Data/Accounts/PiliHTTPRequestHeaderFinalizer.swift',
    'ios/Runner/Native/Networking/HTTP/PiliHTTPClient.swift',
    'ios/Runner/Native/Networking/HTTP/PiliHTTPPolicyCapability.swift',
    'ios/Runner/Native/Data/HTTP/PiliPreparedHTTPRequestExecutor.swift',
    'ios/Runner/Native/Data/Search/PiliFlutterSearchRepository.swift',
    'ios/Runner/Native/Data/Search/PiliSearchTrendingDecoder.swift',
    'ios/Runner/Native/Data/Search/PiliPreparedSearchTrendingLoader.swift',
    'tool/check_prepared_search_trending.swift',
]


def check_trending(context_sources):
    fixture = OUTPUT / 'trending.json'
    if not fixture.is_file():
        raise RuntimeError('Actual Dart trending fixture missing')
    # Compile the same Swift sources as Runner while linking the actual body
    # codec package. Fixture capability flags stay on this temporary target.
    with tempfile.TemporaryDirectory(prefix='piliglass-trending-') as temp:
        package = Path(temp)
        sources = package / 'Sources' / 'TrendingCheck'
        sources.mkdir(parents=True)
        for path in context_sources + TRENDING_SOURCES:
            shutil.copy2(ROOT / path, sources)
        codec_path = json.dumps(str(ROOT / 'Packages/PiliHTTPBodyCodec'), ensure_ascii=False)
        (package / 'Package.swift').write_text(f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "TrendingCheck",
  platforms: [.macOS(.v13)],
  dependencies: [.package(path: {codec_path})],
  targets: [.executableTarget(
    name: "TrendingCheck",
    dependencies: [.product(name: "PiliHTTPBodyCodec", package: "PiliHTTPBodyCodec")],
    swiftSettings: [.define("PILI_HTTP_FIXTURES")]
  )]
)
''', encoding='utf-8')
        command = ['swift', 'run', '--package-path', str(package),
                   '-Xswiftc', '-strict-concurrency=complete', 'TrendingCheck', str(fixture)]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=420)
    output = result.stdout + result.stderr
    (OUTPUT / 'trending.log').write_text(shlex.join(command) + '\n' + output, encoding='utf-8')
    print(output, end='')
    match = re.search(r'(\d+) actual Dart prepared trending cases passed', output)
    if result.returncode or not match:
        raise RuntimeError('Prepared trending composition failed')
    return int(match[1])


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
        executable = OUTPUT / 'check-prepared-http-policy'
        command = ['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete',
                   '-parse-as-library', '-o', str(executable),
                   *(str(ROOT / source) for source in sources), str(ROOT / 'tool/check_prepared_http_policy.swift')]
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
        trending_cases = check_trending(sources)
        summary.update(status='passed', checks=int(match[1]), golden_files=2, golden_cases=16,
                       trending_cases=trending_cases)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        summary['reason'] = str(error)
        print(f'FAIL prepared HTTP policy: {error}')
    (OUTPUT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    return 0 if summary['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
