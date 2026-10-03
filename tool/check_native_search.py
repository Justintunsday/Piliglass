"""Compile and exercise the production native search core on macOS."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/native-search-check"
SOURCES = [
    "ios/Runner/PiliNativeLocalization.swift",
    "ios/Runner/Native/Bridge/PiliBridgeValues.swift",
    "ios/Runner/Native/Bridge/PiliBridgeValue.swift",
    "ios/Runner/Native/Bridge/PiliBridgeMethodInvoker.swift",
    "ios/Runner/Native/Bridge/Models/PiliNativeVideo.swift",
    "ios/Runner/Native/Domain/Search/PiliSearchRepository.swift",
    "ios/Runner/Native/Data/Search/PiliFlutterSearchRepository.swift",
    "ios/Runner/Native/Features/Search/PiliNativeSearchViewState.swift",
    "ios/Runner/Native/Features/Search/PiliNativeSearchModel.swift",
    "tool/check_native_search.swift",
]


def summarize(status, **details):
    (OUTPUT / "summary.json").write_text(
        json.dumps({"status": status, "platform": sys.platform, **details}, indent=2) + "\n",
        encoding="utf-8",
    )


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    if sys.platform != "darwin":
        reason = "macOS Swift and Combine are required; compilation was not verified"
        print(f"SKIP native search checks: {reason} ({sys.platform})")
        summarize("skipped", reason=reason)
        return 0

    executable = OUTPUT / "check-native-search"
    command = ["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
               "-parse-as-library", "-o", str(executable),
               *(str(ROOT / source) for source in SOURCES)]
    try:
        compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
        (OUTPUT / "compile.log").write_text(
            shlex.join(command) + "\n" + compiled.stdout + compiled.stderr, encoding="utf-8"
        )
        if compiled.returncode:
            print(compiled.stdout + compiled.stderr, end="")
            summarize("failed", stage="compile", exit_code=compiled.returncode)
            return compiled.returncode
        result = subprocess.run([str(executable)], cwd=ROOT, capture_output=True, text=True, timeout=30)
        text = result.stdout + result.stderr
        (OUTPUT / "result.log").write_text(text, encoding="utf-8")
        print(text, end="")
        match = re.search(r"(\d+) native search checks passed", text)
        summarize("passed" if result.returncode == 0 and match else "failed", stage="fixtures",
                  exit_code=result.returncode, checks=int(match[1]) if match else None)
        return result.returncode or (0 if match else 1)
    except (OSError, subprocess.TimeoutExpired) as error:
        message = f"Native search checks failed: {error}\n"
        (OUTPUT / "result.log").write_text(message, encoding="utf-8")
        print(message, end="")
        summarize("failed", reason=str(error))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
