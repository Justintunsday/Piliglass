"""Compare native Cookie parser/selector with actual pinned Dart exports."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/native-cookie-contracts"
SOURCES = [
    "ios/Runner/Native/Domain/Accounts/PiliAccountRepository.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliAccountSecretStore.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliNativeCookieParser.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliNativeCookieSelector.swift",
    "tool/check_native_cookies.swift",
]


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = {"status": "failed", "platform": sys.platform, "source": "actual Dart Cookie/CookieJar/getCookies"}
    try:
        if sys.platform != "darwin":
            raise RuntimeError("macOS Swift/Security required; a skip is not verification")
        golden = OUTPUT / "dart.json"
        if not golden.is_file():
            raise RuntimeError("Actual Dart Cookie fixture export missing")
        executable = OUTPUT / "check-native-cookies"
        command = ["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
                   "-parse-as-library", "-o", str(executable), *(str(ROOT / path) for path in SOURCES)]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
        (OUTPUT / "compile.log").write_text(shlex.join(command) + "\n" + result.stdout + result.stderr, encoding="utf-8")
        if result.returncode:
            print(result.stdout + result.stderr, end="")
            raise RuntimeError("Production native Cookie Swift compile failed")
        result = subprocess.run([str(executable), str(golden)], cwd=ROOT, capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        (OUTPUT / "result.log").write_text(output, encoding="utf-8")
        print(output, end="")
        match = re.search(r"(\d+) native Cookie checks passed", output)
        if result.returncode or not match:
            raise RuntimeError("Dart/native Cookie contract mismatch")
        summary.update(status="passed", checks=int(match[1]))
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        summary["reason"] = str(error)
        print(f"FAIL native Cookie contract: {error}")
    (OUTPUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
