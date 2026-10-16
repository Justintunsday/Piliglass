"""Local mocked QA for the envelope pipeline's cross-runtime export phase.

Drives BOTH the real `verify_crossruntime_export` phase and the real `main()`
with only the process-execution seam and the output directory mocked: it proves
the phase fails closed on missing/stale/mutated artifacts, malformed metadata
records and consumer process failures, that a phase failure leaves the summary
failed with exit code 1, and that the fresh-cleanup list in main() ties to the
new outputs. This is local mock QA: it is NOT Mac/Swift/Dart or device runtime
evidence.
"""
from __future__ import annotations

import ast
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile

TOOL = Path(__file__).resolve().parent
ROOT = TOOL.parent
PIPELINE_PATH = TOOL / "check_native_account_envelopes.py"
DRIVER_PATH = TOOL / "check_native_account_envelope_export.swift"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "ios.yml"
MAIN_SHA = os.environ.get("GITHUB_SHA") or "a" * 40
MOCK_WIRE = b'{"schemaVersion":3,"mock":true}'
MOCK_TRANSACTION = "11111111-1111-1111-1111-111111111111"
MOCK_EXPORT_CHECK_LINE = "126 native account envelope export checks passed\n"
STALE_EXPORT_REASON = "Cross-runtime export metadata is absent, stale or mismatched"
CLEANUP_NAMES = [
    "schema3-export.json", "schema3-export-wire.bin", "schema3-export-consumed.json",
    "schema3-export-compile.log", "schema3-export-result.log",
    "schema3-export-consumer-analyze.log", "schema3-export-consumer-test.log",
]
PHASE_FAILURES = [
    "missing_wire", "missing_metadata", "stale_metadata", "mutated_wire",
    "duplicate_metadata_keys", "consumer_failure", "consumer_process_error",
    "missing_consume_record", "tampered_consume_record", "mutated_after_consumer",
]


def load_pipeline():
    spec = importlib.util.spec_from_file_location("envelope_pipeline_qa_target", PIPELINE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ProducerClock:
    """Deterministic microsecond clock for the mocked producer window.

    Every call advances by a fixed step, so with the module's clock injected
    around `main()`, `producer_started < observation started <= observation
    finished < producer_finished` holds on any host clock granularity, without
    sleeps and without touching the production fixture validation.
    """

    def __init__(self, start_microseconds=1_700_000_000_000_000, step_microseconds=5):
        self._now = start_microseconds
        self._step = step_microseconds

    def time_ns(self):
        self._now += self._step
        return self._now * 1000


class FakePipeline:
    """Mock process seam: writes the same output files the real commands would."""

    def __init__(self, root: Path, scenario: str, module, clock=None):
        self.root = root
        self.scenario = scenario
        self.module = module
        self.clock = clock or ProducerClock()
        self.commands = []

    def run(self, command, log, timeout=180):
        self.commands.append(([str(part) for part in command], log))
        (self.root / log).write_text("mock log\n", encoding="utf-8")
        first = str(command[0])
        name = Path(first).name
        joined = " ".join(str(part) for part in command)
        if first == "git":
            if len(command) > 1 and str(command[1]) == "rev-parse":
                return MAIN_SHA + "\n"
            return ""
        if first == "xcrun":
            return ""
        if first == "dart":
            return "No issues found!\n"
        if first == "flutter":
            if "test/utils/accounts/" in joined:
                return self.write_goldens()
            if "native_account_schema3_export_consumption_test.dart" in joined:
                return self.consumer(joined)
            raise AssertionError(f"unexpected flutter command: {joined}")
        if name == "check-native-account-envelopes":
            return ("109 native account envelope checks passed; actualDartObservations=10 "
                    "negativeCases=44 syntheticIntegerCases=1 runtimeEnabled=false\n")
        if name == "check-native-account-envelope-staging":
            return "40 native account envelope staging checks passed\n"
        if name == "check-native-account-envelope-transaction":
            return "108 native account envelope transaction checks passed\n"
        if name == "check-native-account-envelope-transaction-identity":
            return "177 native account envelope identity transaction checks passed\n"
        if name == "check-native-account-envelope-queue":
            return "292 native account envelope queue checks passed\n"
        if name == "check-native-account-authority":
            return "51 native account authority checks passed\n"
        if name == "check-native-account-envelope-export":
            return self.producer()
        raise AssertionError(f"unexpected command: {joined}")

    @staticmethod
    def golden_case(case_id, started, finished):
        return {
            "id": case_id,
            "captureStartedMicroseconds": started,
            "captureFinishedMicroseconds": finished,
            "envelope": {
                "schemaVersion": 2,
                "scope": "coherentLiveMemoryShadow",
                "identityScope": "captureLocal",
                "durableIdentityConfigured": False,
                "durabilityVerified": False,
                "authoritySwitchAllowed": False,
                "nativeWritesAllowed": False,
            },
        }

    def write_goldens(self):
        started = self.clock.time_ns() // 1000
        finished = self.clock.time_ns() // 1000
        window = (started, finished)
        live = {
            "schemaVersion": 1,
            "source": "actual Accounts / real Hive / production live-memory capture service",
            "runtimeCutover": False,
            "durableIdentityConfigured": False,
            "clockPolicy": {
                "kind": "actualDartDateTimeNow",
                "injectedClock": False,
                "exactBoundaryProof": False,
            },
            "cases": [self.golden_case(case_id, *window) for case_id in self.module.LIVE_IDS],
        }
        cold = {
            "schemaVersion": 1,
            "source": "actual Hive type8/type9 write-close-reopen / production capture service",
            "runtimeCutover": False,
            "durableIdentityConfigured": False,
            "crossRestartStampContinuity": False,
            "preHiveJarObservations": [{"mock": 1}, {"mock": 2}],
            "clockPolicy": {
                "kind": "actualDartDateTimeNow",
                "injectedClock": False,
                "exactBoundaryProof": False,
            },
            "cases": [self.golden_case(case_id, *window) for case_id in self.module.COLD_IDS],
        }
        (self.root / "live-memory.json").write_text(json.dumps(live), encoding="utf-8")
        (self.root / "hive-reopened.json").write_text(json.dumps(cold), encoding="utf-8")
        return "00:00 +8: All tests passed!\n"

    def producer_metadata(self, digest):
        return {
            "schema": "pili.account.schema3-export.v1",
            "sourceSHA": MAIN_SHA,
            "workflowSHA": None,
            "transactionID": MOCK_TRANSACTION,
            "envelopeSchemaVersion": 3,
            "envelopeByteCount": len(MOCK_WIRE),
            "envelopeSHA256": digest,
            "wireFileName": "schema3-export-wire.bin",
        }

    def producer(self):
        digest = hashlib.sha256(MOCK_WIRE).hexdigest()
        metadata = self.producer_metadata(digest)
        if self.scenario == "missing_wire":
            (self.root / "schema3-export.json").write_text(json.dumps(metadata), encoding="utf-8")
            return MOCK_EXPORT_CHECK_LINE
        if self.scenario == "missing_metadata":
            (self.root / "schema3-export-wire.bin").write_bytes(MOCK_WIRE)
            return MOCK_EXPORT_CHECK_LINE
        if self.scenario == "duplicate_metadata_keys":
            (self.root / "schema3-export-wire.bin").write_bytes(MOCK_WIRE)
            text = ('{"schema":"pili.account.schema3-export.v1",'
                    '"sourceSHA":"%s","sourceSHA":"%s","workflowSHA":null,'
                    '"transactionID":"%s","envelopeSchemaVersion":3,'
                    '"envelopeByteCount":%d,"envelopeSHA256":"%s",'
                    '"wireFileName":"schema3-export-wire.bin"}'
                    % (MAIN_SHA, MAIN_SHA, MOCK_TRANSACTION, len(MOCK_WIRE), digest))
            (self.root / "schema3-export.json").write_text(text, encoding="utf-8")
            return MOCK_EXPORT_CHECK_LINE
        if self.scenario == "stale_metadata":
            metadata["sourceSHA"] = "b" * 40
        if self.scenario == "main_stale_export":
            metadata["sourceSHA"] = "b" * 40
        if self.scenario == "mutated_wire":
            (self.root / "schema3-export-wire.bin").write_bytes(b"tampered")
        else:
            (self.root / "schema3-export-wire.bin").write_bytes(MOCK_WIRE)
        (self.root / "schema3-export.json").write_text(json.dumps(metadata), encoding="utf-8")
        return MOCK_EXPORT_CHECK_LINE

    def consumer(self, joined):
        assert "--dart-define=NATIVE_ACCOUNT_SCHEMA3_EXPORT=" in joined
        assert "--dart-define=NATIVE_ACCOUNT_SCHEMA3_SOURCE=" in joined
        assert "live-memory.json" in joined
        assert "test/services/native_accounts/native_account_schema3_export_consumption_test.dart" in joined
        if self.scenario == "consumer_process_error":
            raise RuntimeError("schema3-export-consumer-test.log: command failed (1)")
        if self.scenario == "consumer_failure":
            return "00:00 +5 -1: Some tests failed.\n"
        metadata = json.loads((self.root / "schema3-export.json").read_text(encoding="utf-8"))
        digest = metadata["envelopeSHA256"]
        if self.scenario == "mutated_after_consumer":
            (self.root / "schema3-export-wire.bin").write_bytes(b"tampered-after-consumer")
        if self.scenario == "tampered_consume_record":
            digest = "0" * 64
        if self.scenario != "missing_consume_record":
            consumed = {
                "schema": "pili.account.schema3-export.consumed.v1",
                "transactionID": metadata["transactionID"],
                "envelopeSHA256": digest,
                "envelopeByteCount": metadata["envelopeByteCount"],
            }
            (self.root / "schema3-export-consumed.json").write_text(
                json.dumps(consumed), encoding="utf-8")
        return "00:00 +6: All tests passed!\n"


def run_phase(module, scenario, workflow_sha=None):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        fake = FakePipeline(root, scenario, module)
        previous_output = module.OUTPUT
        previous_run = module.run
        module.OUTPUT = root
        module.run = fake.run
        try:
            evidence = module.verify_crossruntime_export(MAIN_SHA, workflow_sha)
        finally:
            module.OUTPUT = previous_output
            module.run = previous_run
        return evidence, fake


def run_main(module, scenario, clock=None):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        fake = FakePipeline(root, scenario, module, clock=clock)
        previous_output = module.OUTPUT
        previous_run = module.run
        previous_time = module.time
        previous_platform = sys.platform
        module.OUTPUT = root
        module.run = fake.run
        module.time = clock or ProducerClock()
        sys.platform = "darwin"
        try:
            with redirect_stdout(io.StringIO()):
                exit_code = module.main()
        finally:
            sys.platform = previous_platform
            module.time = previous_time
            module.OUTPUT = previous_output
            module.run = previous_run
        summary = json.loads((root / "summary.json").read_text(encoding="utf-8"))
        return exit_code, summary, fake


def check_phase_success(module):
    evidence, fake = run_phase(module, "happy")
    assert evidence["transactionID"] == MOCK_TRANSACTION
    assert evidence["wireByteCount"] == len(MOCK_WIRE)
    assert evidence["consumerTests"] == 6
    assert evidence["exportChecks"] == 126
    assert len(evidence["metadataSHA256"]) == 64
    assert len(evidence["wireSHA256"]) == 64
    logs = [log for _, log in fake.commands]
    for log in ("schema3-export-compile.log", "schema3-export-result.log",
                "schema3-export-consumer-analyze.log", "schema3-export-consumer-test.log"):
        assert log in logs, f"phase did not run {log}"


def expect_failure(module, scenario):
    try:
        run_phase(module, scenario)
    except (RuntimeError, ValueError):
        return
    raise AssertionError(f"pipeline did not fail closed on {scenario}")


def check_phase_wrong_workflow(module):
    try:
        run_phase(module, "happy", workflow_sha="c" * 40)
    except RuntimeError:
        return
    raise AssertionError("pipeline accepted a mismatched workflow SHA")


def check_main_success(module):
    # Two different clock bases: the deterministic producer window must hold on
    # any boundary, without host clock granularity involvement.
    for clock in (ProducerClock(0, 5), ProducerClock(1_700_000_000_000_000, 7)):
        exit_code, summary, fake = run_main(module, "happy", clock=clock)
        assert exit_code == 0, summary.get("reason")
        assert summary["status"] == "passed"
        assert summary["sourceSHA"] == MAIN_SHA
        export = summary["schema3Export"]
        assert export["exportChecks"] == 126
        assert export["consumerTests"] == 6
        assert export["transactionID"] == MOCK_TRANSACTION
        assert len(export["wireSHA256"]) == 64
        commands = [" ".join(command) for command, _ in fake.commands]
        assert any("check-native-account-envelope-export" in command for command in commands), \
            "main() never reached the cross-runtime export phase"


def check_main_failure(module):
    exit_code, summary, fake = run_main(module, "main_stale_export")
    assert exit_code == 1, "a failed phase must exit non-zero"
    assert summary["status"] == "failed"
    assert summary.get("reason") == STALE_EXPORT_REASON, \
        f"failed summary must record the intended stale-export cause, got {summary.get('reason')!r}"
    commands = [" ".join(command) for command, _ in fake.commands]
    assert any("check-native-account-envelope-export" in command for command in commands), \
        "the cross-runtime export phase was never reached; an earlier failure cannot prove this negative path"
    assert any("test/utils/accounts/" in command for command in commands), \
        "the producer phase never ran before the intended stale-export failure"


def check_static_wiring():
    source = PIPELINE_PATH.read_text(encoding="utf-8")
    tree = ast.parse(source)
    main = next(node for node in tree.body
                if isinstance(node, ast.FunctionDef) and node.name == "main")
    cleanup = None
    for node in ast.walk(main):
        if isinstance(node, ast.For) and isinstance(node.iter, ast.List):
            names = [elt.value for elt in node.iter.elts if isinstance(elt, ast.Constant)]
            if "live-memory.json" in names:
                cleanup = names
    assert cleanup is not None, "main() fresh-cleanup unlink list not found"
    for name in CLEANUP_NAMES:
        assert name in cleanup, f"fresh cleanup list is missing {name}"
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
    for symbol in ("EXPORT_SOURCES", "EXPORT_CONSUMER", "EXPORT_QA"):
        assert symbol in source, f"source ledger is missing {symbol}"
    workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
    assert "python3 tool/check_native_account_envelopes.py" in workflow
    assert "ACCOUNT_ENVELOPE_OUTCOME: ${{ steps.group-account-envelope.outcome }}" in workflow
    assert "build/native-account-envelope-check/*.bin" in workflow
    assert '"test/services/native_accounts/**"' in workflow


def check_driver_fixture_consistency():
    """Static fixture-consistency QA for the changed-manifest cancellation row.

    Source-level only: the reminted manifest must be a pointer-only mutation
    (transaction ID changed, byte count and digest untouched), and the row must
    carry its independent expected-mutation / restore labels. This is not Swift
    execution evidence.
    """
    source = DRIVER_PATH.read_text(encoding="utf-8")
    match = re.search(
        r"private static func remintedManifest\(_ bytes: Data\) throws -> Data \{(?P<body>.*?)\n  \}",
        source, re.S)
    assert match is not None, "remintedManifest function body not found"
    body = match.group("body")
    assert 'object["transactionID"] = UUID().uuidString.lowercased()' in body, \
        "changed-manifest fixture must remint the transaction ID"
    assert "byteCount" not in body and "sha256" not in body, \
        "changed-manifest fixture must be a pointer-only mutation"
    for label in ("changed-manifest cancel preserves the exact independently expected fixture mutation",
                  "cleanup restores the original vault bytes"):
        assert label in source, f"changed-manifest row is missing its expected-state label: {label}"


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
    for scenario in PHASE_FAILURES:
        attempt(f"phase fails closed on {scenario}",
                lambda scenario=scenario: expect_failure(module, scenario))
    attempt("phase rejects a mismatched workflow SHA",
            lambda: check_phase_wrong_workflow(module))
    attempt("full main() mock passes with the phase evidence",
            lambda: check_main_success(module))
    attempt("full main() mock fails summary/exit1 on a stale export",
            lambda: check_main_failure(module))
    attempt("static pipeline/workflow wiring", check_static_wiring)
    attempt("driver changed-manifest fixture consistency", check_driver_fixture_consistency)
    failed = 0
    for label, passed, detail in results:
        if passed:
            print(f"PASS {label}")
        else:
            failed += 1
            print(f"FAIL {label} ({detail})")
    print(f"QA native account envelope export: {len(results) - failed}/{len(results)} "
          "local mock checks passed")
    print("QA note: local mocked Python QA only - NOT Mac/Swift/Dart/device runtime evidence; "
          "the mock '126 native ... checks passed' lines are MOCK subprocess output, not a "
          "Swift execution count")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
