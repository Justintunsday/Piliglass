"""Compile production login layers and replay actual Dart/Dio/RSA goldens."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'build/native-login-contract'
SOURCES = [
    'ios/Runner/Native/Bridge/PiliBridgeValue.swift',
    'ios/Runner/Native/Bridge/PiliBridgeMethodInvoker.swift',
    'ios/Runner/Native/Domain/Accounts/PiliAccountRepository.swift',
    'ios/Runner/Native/Domain/Login/PiliLoginRepository.swift',
    'ios/Runner/Native/Networking/Auth/PiliNativeSigner.swift',
    'ios/Runner/Native/Data/Login/PiliLoginRequestBuilder.swift',
    'ios/Runner/Native/Data/Login/PiliLoginResponseDecoder.swift',
    'ios/Runner/Native/Data/Login/PiliNativeLoginRepository.swift',
    'ios/Runner/Native/Data/Login/PiliLoginRSAEncryptor.swift',
    'ios/Runner/Native/Data/Login/PiliLoginLogoutService.swift',
    'ios/Runner/Native/Data/Login/PiliFlutterLoginAccountAuthority.swift',
    'ios/Runner/Native/Features/Account/Login/PiliLoginSession.swift',
    'ios/Runner/Native/Features/Account/Login/PiliGeetestWebSession.swift',
    'tool/check_native_login.swift',
]


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = {'status': 'failed', 'platform': sys.platform, 'source': 'actual LoginHttp/Dio/RSA/Hive fixture'}
    try:
        if sys.platform != 'darwin':
            raise RuntimeError('macOS Swift required; local static review is not compilation acceptance')
        golden = OUTPUT / 'dart-goldens.json'
        if not golden.is_file():
            raise RuntimeError('actual Dart login golden missing')
        executable = OUTPUT / 'check-native-login'
        command = ['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-parse-as-library',
                   '-o', str(executable), *(str(ROOT / source) for source in SOURCES)]
        compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=180)
        (OUTPUT / 'compile.log').write_text(shlex.join(command) + '\n' + compiled.stdout + compiled.stderr, encoding='utf-8')
        if compiled.returncode:
            print(compiled.stdout + compiled.stderr, end='')
            raise RuntimeError('production login Swift compile failed')
        result = subprocess.run([str(executable), str(golden), str(ROOT / 'tool/native_login_synthetic_rsa.json')],
                                cwd=ROOT, capture_output=True, text=True, timeout=45)
        output = result.stdout + result.stderr
        (OUTPUT / 'result.log').write_text(output, encoding='utf-8')
        print(output, end='')
        match = re.search(r'(\d+) native login checks passed', output)
        if result.returncode or not match:
            raise RuntimeError('Dart-to-Swift login contract failed')
        summary.update(status='passed', checks=int(match[1]), golden_cases=20)
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        summary['reason'] = str(error)
        print(f'FAIL native login: {error}')
    (OUTPUT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    return 0 if summary['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
