"""Consume real Hive/Dart exports with production Swift account and vault code."""
import hashlib
import json
import os
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
# The actual Dart producers of this contract's two golden exports plus the
# bridge/service that route them: hashed so this component carries its own
# compiled/consumed input provenance instead of borrowing another ledger.
PRODUCERS = [
    "test/utils/accounts/native_account_snapshot_test.dart",
    "test/utils/accounts/native_account_hive_export_test.dart",
]
BRIDGE = [
    "lib/services/native_accounts/native_account_snapshot_service.dart",
    "lib/services/native_accounts/native_account_snapshot_bridge.dart",
]


def source_hashes():
    files = {ROOT / path for path in [*SOURCES, *PRODUCERS, *BRIDGE]}
    files.add(Path(__file__).resolve())
    missing = [path for path in files if not path.is_file()]
    if missing:
        raise RuntimeError("Contract source absent: " + ", ".join(sorted(str(path) for path in missing)))
    return {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(files)}


def input_hashes(paths):
    return {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


def head_revision(log):
    result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    (OUTPUT / log).write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError("git rev-parse HEAD failed")
    return result.stdout.strip()


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = {"status": "failed", "platform": sys.platform, "source": "actual Hive/Dart exports"}
    try:
        if sys.platform != "darwin":
            raise RuntimeError("macOS Swift/Security required; a skip cannot verify this contract")
        source_sha = head_revision("source-revision.log")
        workflow_sha = os.environ.get("GITHUB_SHA")
        if not re.fullmatch(r"[0-9a-f]{40}", source_sha) or (workflow_sha and workflow_sha != source_sha):
            raise RuntimeError("Actual checkout/workflow source SHA mismatch")
        summary.update(sourceSHA=source_sha, workflowSHA=workflow_sha)
        source_digests = source_hashes()
        summary["sourceSHA256"] = source_digests
        paths = [OUTPUT / name for name in ["live.json", "hive-reopened.json"]]
        if not all(path.is_file() for path in paths):
            raise RuntimeError("Run Flutter account fixtures first; actual Dart/Hive goldens missing")
        input_digests = input_hashes(paths)
        summary["inputSHA256"] = input_digests
        (OUTPUT / "source-hashes-before.log").write_text(
            json.dumps({"sourceSHA256": source_digests, "inputSHA256": input_digests}, indent=2) + "\n",
            encoding="utf-8")
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
        if source_hashes() != source_digests or input_hashes(paths) != input_digests:
            raise RuntimeError("Contract sources or actual golden inputs changed during verification")
        if head_revision("source-revision-after.log") != source_sha:
            raise RuntimeError("Contract checkout changed during verification")
        summary.update(status="passed", checks=int(match[1]), golden_files=2)
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        summary["reason"] = str(error)
        print(f"FAIL native accounts: {error}")
    (OUTPUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
