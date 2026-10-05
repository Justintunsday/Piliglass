"""Actual Dart jar2 exports, strict Swift codec and isolated Keychain restart."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/native-ordered-cookie-check"
PRODUCERS = [
    "test/utils/accounts/native_ordered_cookie_export_test.dart",
    "test/utils/accounts/native_ordered_cookie_mutations_test.dart",
]


def run(command, log, timeout=180):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    output = result.stdout + result.stderr
    (OUTPUT / log).write_text(shlex.join(command) + "\n" + output, encoding="utf-8")
    if result.returncode:
        print(result.stdout[-8000:])
        print(result.stderr[-8000:])
        raise RuntimeError(f"{log}: command failed ({result.returncode})")
    return output


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = dict(status="failed", platform=sys.platform, runtimeEnabled=False,
                   scope="jar2 shadow format and store; no account authority or Native mutation engine")
    try:
        if sys.platform != "darwin":
            raise RuntimeError("macOS Swift/Security required; a skip is not verification")
        for name in ["exporter.json", "mutations.json", "hive-reopened.json"]:
            (OUTPUT / name).unlink(missing_ok=True)
        run(["dart", "analyze", "--fatal-infos",
             "lib/services/native_accounts/native_ordered_cookie_jar_export.dart", *PRODUCERS], "analyze.log")
        run(["flutter", "test", "--no-pub", "--reporter", "expanded", *PRODUCERS], "dart-test.log", timeout=180)
        if not all((OUTPUT / name).is_file() for name in ["exporter.json", "mutations.json", "hive-reopened.json"]):
            raise RuntimeError("Actual Dart/Hive evidence missing")
        # These are the new production jar files only. The account authority,
        # old schema1 codec, UI and HTTP transport stay outside this boundary.
        archive_sources = sorted(path for folder in ["Domain", "Data"]
                                 for path in (ROOT / "ios/Runner/Native" / folder / "Accounts").glob("PiliOrderedCookie*.swift"))
        base = ["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library"]
        golden_paths = [str(OUTPUT / name) for name in ["exporter.json", "mutations.json"]]
        for kind in ["codec", "staging"]:
            executable = OUTPUT / ("check-ordered-cookie-" + kind)
            if kind == "codec":
                sources = [*archive_sources, ROOT / "tool/check_native_ordered_cookies.swift"]
                arguments = golden_paths
            else:
                sources = [*archive_sources,
                           ROOT / "ios/Runner/Native/Domain/Accounts/PiliAccountRepository.swift",
                           ROOT / "ios/Runner/Native/Persistence/Accounts/PiliAccountSecretStore.swift",
                           ROOT / "ios/Runner/Native/Persistence/Accounts/PiliOrderedCookieStagingStore.swift",
                           ROOT / "tool/check_native_ordered_cookie_staging.swift"]
                arguments = golden_paths[:1]
            run([*base, "-o", str(executable), *(str(path) for path in sources)], f"{kind}-compile.log")
            output = run([str(executable), *arguments], f"{kind}-result.log", timeout=90)
            print(output, end="")
            match = re.search(rf"(\d+) native ordered Cookie {kind} checks passed", output)
            if not match:
                raise RuntimeError(f"{kind} executable did not report verified checks")
            summary[kind + "Checks"] = int(match[1])
        summary.update(status="passed", actualDartGoldens=3)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        summary["reason"] = str(error)
        print(f"FAIL ordered Cookie jar: {error}")
    (OUTPUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
