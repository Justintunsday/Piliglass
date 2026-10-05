"""Replay fresh actual Dart CookieJar operations through the native candidate."""
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/native-cookie-mutation-check"
GOLDENS = ROOT / "build/native-ordered-cookie-check"
SOURCES = [
    "ios/Runner/Native/Domain/Accounts/PiliAccountRepository.swift",
    "ios/Runner/Native/Domain/Accounts/PiliOrderedCookieArchive.swift",
    "ios/Runner/Native/Data/Accounts/PiliOrderedCookieArchiveCodec.swift",
    "ios/Runner/Native/Data/Accounts/PiliNativeOrderedCookieReducer.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliAccountSecretStore.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliNativeCookieParser.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliNativeCookieSelector.swift",
    "tool/check_native_cookie_mutations.swift",
]


def run(command, log):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=180)
    output = result.stdout + result.stderr
    (OUTPUT / log).write_text(shlex.join(command) + "\n" + output, encoding="utf-8")
    if result.returncode:
        print(output[-10000:])
        raise RuntimeError(f"{log}: command failed ({result.returncode})")
    return output


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = dict(status="failed", platform=sys.platform, runtimeEnabled=False,
                   scope="pure ordered jar mutation candidate; no account authority")
    try:
        if sys.platform != "darwin":
            raise RuntimeError("macOS Swift/Security required; a skip is not verification")
        # The preceding ordered-jar step deletes its goldens before producing
        # them and always rewrites its summary. A failed producer cannot supply
        # a stale successful input to this dependent check in the same CI job.
        producer = json.loads((GOLDENS / "summary.json").read_text(encoding="utf-8"))
        if producer.get("status") != "passed" or producer.get("actualDartGoldens") != 3:
            raise RuntimeError("Fresh actual Dart/strict ordered-jar group did not pass")
        golden = GOLDENS / "mutations.json"
        payload = golden.read_bytes()
        (OUTPUT / "mutations.json").write_bytes(payload)
        executable = OUTPUT / "check-cookie-mutations"
        executable.unlink(missing_ok=True)
        run(["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
             "-parse-as-library", "-o", str(executable), *SOURCES], "compile.log")
        output = run([str(executable), str(OUTPUT / "mutations.json")], "result.log")
        print(output, end="")
        match = re.search(r"(\d+) native ordered Cookie mutation checks passed; "
                          r"(\d+) actual Dart operations, (\d+) actual headers", output)
        if not match or int(match[2]) < 34 or int(match[3]) < 43:
            raise RuntimeError("Independent replay did not report required operation/header coverage")
        summary.update(status="passed", checks=int(match[1]), actualDartOperations=int(match[2]),
                       actualDartHeaders=int(match[3]), goldenSHA256=hashlib.sha256(payload).hexdigest())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        summary["reason"] = str(error)
        print(f"FAIL ordered Cookie mutation: {error}")
    (OUTPUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
