"""Consume real Hive/Dart exports with production Swift account and vault code."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/native-account-contracts"
SOURCES = [
    "ios/Runner/Native/Bridge/PiliBridgeValue.swift",
    "ios/Runner/Native/Bridge/PiliBridgeMethodInvoker.swift",
    "ios/Runner/Native/Domain/Accounts/PiliAccountRepository.swift",
    "ios/Runner/Native/Data/Accounts/PiliAccountSnapshotBridgeCodec.swift",
    "ios/Runner/Native/Data/Accounts/PiliAccountFlutterRepository.swift",
    "ios/Runner/Native/Data/Accounts/PiliAccountStagingBridgeCodec.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliAccountSecretStore.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliAccountStagingStore.swift",
    "tool/check_native_accounts.swift",
]


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = {"status": "failed", "platform": sys.platform, "source": "actual Hive/Dart exports"}
    try:
        if sys.platform != "darwin":
            raise RuntimeError("macOS Swift/Security required; a skip cannot verify this contract")
        paths = [OUTPUT / name for name in ["live.json", "hive-reopened.json"]]
        if not all(path.is_file() for path in paths):
            raise RuntimeError("Run Flutter account fixtures first; actual Dart/Hive goldens missing")
        executable = OUTPUT / "check-native-accounts"
        command = ["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
                   "-parse-as-library", "-o", str(executable), *(str(ROOT / path) for path in SOURCES)]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
        (OUTPUT / "compile.log").write_text(shlex.join(command) + "\n" + result.stdout + result.stderr, encoding="utf-8")
        if result.returncode:
            print(result.stdout + result.stderr, end="")
            raise RuntimeError("Production account Swift compile failed")
        result = subprocess.run([str(executable), *(str(path) for path in paths)], cwd=ROOT,
                                capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        (OUTPUT / "result.log").write_text(output, encoding="utf-8")
        print(output, end="")
        match = re.search(r"(\d+) native account checks passed", output)
        if result.returncode or not match:
            raise RuntimeError("Native account/staging contracts failed")
        summary.update(status="passed", checks=int(match[1]), golden_files=2)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        summary["reason"] = str(error)
        print(f"FAIL native accounts: {error}")
    (OUTPUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
