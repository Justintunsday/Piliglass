"""Local mocked negative QA for the cross-runtime export phase.

Drives the REAL `verify_crossruntime_export` implementation from
tool/check_native_account_envelopes.py with only the process-execution seam and
the output directory mocked: it proves the phase fails closed on missing,
stale and mutated artifacts plus consumer failures, and that the phase runs
inside `main()` before the passed summary while its outputs are always cleaned.
This is local mock QA: it is NOT Mac/Swift/Dart or device runtime evidence.
"""
from __future__ import annotations

import ast
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile

TOOL = Path(__file__).resolve().parent
ROOT = TOOL.parent
PIPELINE_PATH = TOOL / "check_native_account_envelopes.py"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "ios.yml"
SOURCE_SHA = "a" * 40
MOCK_WIRE = b'{"schemaVersion":3,"mock":true}'
CLEANUP_NAMES = [
    "schema3-export.json", "schema3-export-wire.bin", "schema3-export-consumed.json",
    "schema3-export-compile.log", "schema3-export-result.log",
    "schema3-export-consumer-analyze.log", "schema3-export-consumer-test.log",
]
SCENARIOS = ["missing_wire", "stale_metadata", "mutated_wire", "consumer_failure",
             "mutated_after_consumer"]


def load_pipeline():
    spec = importlib.util.spec_from_file_location("envelope_pipeline_qa_target", PIPELINE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakePipeline:
    """Mock process seam: writes the same output files the real commands would."""

    def __init__(self, root: Path, scenario: str):
        self.root = root
        self.scenario = scenario
        self.commands = []

    def run(self, command, log, timeout=180):
        self.commands.append(([str(part) for part in command], log))
        (self.root / log).write_text("mock log\n", encoding="utf-8")
        first = str(command[0])
        joined = " ".join(str(part) for part in command)
        if first == "xcrun":
            return ""
        if first.endswith("check-native-account-envelope-export"):
            return self.producer()
        if first == "dart":
            return "No issues found!\n"
        if first == "flutter":
            return self.consumer(joined)
        raise AssertionError(f"unexpected command: {joined}")

    def producer(self):
        digest = hashlib.sha256(MOCK_WIRE).hexdigest()
        metadata = {
            "schema": "pili.account.schema3-export.v1",
            "sourceSHA": SOURCE_SHA,
            "workflowSHA": None,
            "transactionID": "11111111-1111-1111-1111-111111111111",
            "envelopeSchemaVersion": 3,
            "envelopeByteCount": len(MOCK_WIRE),
            "envelopeSHA256": digest,
            "wireFileName": "schema3-export-wire.bin",
        }
        if self.scenario == "missing_wire":
            (self.root / "schema3-export.json").write_text(json.dumps(metadata), encoding="utf-8")
            return "50 native account envelope export checks passed\n"
        if self.scenario == "mutated_wire":
            (self.root / "schema3-export-wire.bin").write_bytes(b"tampered")
        else:
            (self.root / "schema3-export-wire.bin").write_bytes(MOCK_WIRE)
        if self.scenario == "stale_metadata":
            metadata["sourceSHA"] = "b" * 40
        (self.root / "schema3-export.json").write_text(json.dumps(metadata), encoding="utf-8")
        return "50 native account envelope export checks passed\n"

    def consumer(self, joined):
        assert "--dart-define=NATIVE_ACCOUNT_SCHEMA3_EXPORT=" in joined
        assert "--dart-define=NATIVE_ACCOUNT_SCHEMA3_SOURCE=" in joined
        assert "live-memory.json" in joined
        assert "test/services/native_accounts/native_account_schema3_export_consumption_test.dart" in joined
        if self.scenario == "consumer_failure":
            return "00:00 +5 -1: Some tests failed.\n"
        metadata = json.loads((self.root / "schema3-export.json").read_text(encoding="utf-8"))
        if self.scenario == "mutated_after_consumer":
            (self.root / "schema3-export-wire.bin").write_bytes(b"tampered-after-consumer")
        consumed = {
            "schema": "pili.account.schema3-export.consumed.v1",
            "transactionID": metadata["transactionID"],
            "envelopeSHA256": metadata["envelopeSHA256"],
            "envelopeByteCount": metadata["envelopeByteCount"],
        }
        (self.root / "schema3-export-consumed.json").write_text(
            json.dumps(consumed), encoding="utf-8")
        return "00:00 +6: All tests passed!\n"


def run_phase(module, scenario):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        fake = FakePipeline(root, scenario)
        module.OUTPUT = root
        module.run = fake.run
        evidence = module.verify_crossruntime_export(SOURCE_SHA, None)
        return evidence, fake


def check_phase_success(module):
    evidence, fake = run_phase(module, "happy")
    assert evidence["transactionID"] == "11111111-1111-1111-1111-111111111111"
    assert evidence["wireByteCount"] == len(MOCK_WIRE)
    assert evidence["consumerTests"] == 6
    assert evidence["exportChecks"] == 50
    assert len(evidence["metadataSHA256"]) == 64
    assert len(evidence["wireSHA256"]) == 64
    logs = [log for _, log in fake.commands]
    for log in ("schema3-export-compile.log", "schema3-export-result.log",
                "schema3-export-consumer-analyze.log", "schema3-export-consumer-test.log"):
        assert log in logs, f"phase did not run {log}"


def expect_failure(module, scenario):
    try:
        run_phase(module, scenario)
    except RuntimeError:
        return
    raise AssertionError(f"pipeline did not fail closed on {scenario}")


def check_static_wiring():
    source = PIPELINE_PATH.read_text(encoding="utf-8")
    tree = ast.parse(source)
    main = next(node for node in tree.body
                if isinstance(node, ast.FunctionDef) and node.name == "main")
    export_lines = []
    passed_lines = []
    for node in ast.walk(main):
        if not isinstance(node, ast.Call):
            continue
        if isinstance(node.func, ast.Name) and node.func.id == "verify_crossruntime_export":
            export_lines.append(node.lineno)
        if isinstance(node.func, ast.Attribute) and node.func.attr == "update":
            for keyword in node.keywords:
                if (keyword.arg == "status" and isinstance(keyword.value, ast.Constant)
                        and keyword.value.value == "passed"):
                    passed_lines.append(node.lineno)
    assert export_lines, "main() does not call verify_crossruntime_export"
    assert passed_lines, "main() no longer writes a passed summary"
    assert min(export_lines) < min(passed_lines), \
        "cross-runtime phase must run before the passed summary"
    for name in CLEANUP_NAMES:
        assert f'"{name}"' in source, f"fresh cleanup list is missing {name}"
    for symbol in ("EXPORT_SOURCES", "EXPORT_CONSUMER", "EXPORT_QA"):
        assert symbol in source, f"source ledger is missing {symbol}"
    workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
    assert "python3 tool/check_native_account_envelopes.py" in workflow
    assert "ACCOUNT_ENVELOPE_OUTCOME: ${{ steps.group-account-envelope.outcome }}" in workflow
    assert "build/native-account-envelope-check/*.bin" in workflow
    assert '"test/services/native_accounts/**"' in workflow


def main() -> int:
    module = load_pipeline()
    results = []

    def attempt(label, action):
        try:
            action()
        except Exception as error:  # noqa: BLE001 - QA reports every failure
            results.append((label, False, f"{type(error).__name__}: {error}"))
        else:
            results.append((label, True, ""))

    attempt("phase happy mock returns the exact evidence",
            lambda: check_phase_success(module))
    for scenario in SCENARIOS:
        attempt(f"phase fails closed on {scenario}",
                lambda scenario=scenario: expect_failure(module, scenario))
    attempt("static pipeline/workflow wiring", check_static_wiring)
    failed = 0
    for label, passed, detail in results:
        if passed:
            print(f"PASS {label}")
        else:
            failed += 1
            print(f"FAIL {label} ({detail})")
    print(f"QA native account envelope export: {len(results) - failed}/{len(results)} "
          "local mock checks passed")
    print("QA note: local mocked Python QA only - NOT Mac/Swift/Dart/device runtime evidence")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
