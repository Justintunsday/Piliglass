"""Local mocked QA for the envelope pipeline's two cross-runtime stages.

Drives BOTH stage configurations of the real `verify_crossruntime_stage`
function (export and bootstrap) and the real `main()` with only the
process-execution seam and the output directory mocked: it proves each stage
fails closed on missing/stale/mutated artifacts, malformed metadata records,
wrong-stage UUID consumption, consumer process failures and retained-record
tampering, that a stage failure leaves the summary failed with exit code 1 and
the stage-specific cause, and that the fresh-cleanup list and the post-ALL
six-artifact recheck tie to the new outputs. This is local mock QA: it is NOT
Mac/Swift/Dart or device runtime evidence.
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
EXPORT_DRIVER_PATH = TOOL / "check_native_account_envelope_export.swift"
BOOTSTRAP_DRIVER_PATH = TOOL / "check_native_account_envelope_bootstrap.swift"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "ios.yml"
MAIN_SHA = os.environ.get("GITHUB_SHA") or "a" * 40
MOCK_WIRE = b'{"schemaVersion":3,"mock":true}'
MOCK_TRANSACTION = "11111111-1111-1111-1111-111111111111"
MOCK_BOOTSTRAP_TRANSACTION = "22222222-2222-2222-2222-222222222222"
STAGES = {
    "export": {
        "metadata": "schema3-export.json",
        "wire": "schema3-export-wire.bin",
        "executable": "check-native-account-envelope-export",
        "compile_log": "schema3-export-compile.log",
        "result_log": "schema3-export-result.log",
        "consumer_test_log": "schema3-export-consumer-test.log",
        "retained": "schema3-export.consumed.retained.json",
        "check_line": "126 native account envelope export checks passed\n",
        "checks": 126,
        "transaction": MOCK_TRANSACTION,
    },
    "bootstrap": {
        "metadata": "schema3-bootstrap-export.json",
        "wire": "schema3-bootstrap-wire.bin",
        "executable": "check-native-account-envelope-bootstrap",
        "compile_log": "schema3-bootstrap-compile.log",
        "result_log": "schema3-bootstrap-result.log",
        "consumer_test_log": "schema3-bootstrap-consumer-test.log",
        "retained": "schema3-bootstrap.consumed.retained.json",
        "check_line": "181 native account envelope bootstrap checks passed\n",
        "checks": 181,
        "transaction": MOCK_BOOTSTRAP_TRANSACTION,
    },
}
STALE_EXPORT_REASON = "Cross-runtime export metadata is absent, stale or mismatched"
STALE_BOOTSTRAP_REASON = "Cross-runtime bootstrap metadata is absent, stale or mismatched"
TAMPERED_RETAINED_REASON = ("Cross-runtime artifact schema3-export.consumed.retained.json "
                            "changed across the two stages")
CLEANUP_NAMES = [
    "schema3-export.json", "schema3-export-wire.bin", "schema3-export-consumed.json",
    "schema3-export-compile.log", "schema3-export-result.log",
    "schema3-export-consumer-analyze.log", "schema3-export-consumer-test.log",
    "schema3-export.consumed.retained.json",
    "check-native-account-envelope-bootstrap", "schema3-bootstrap-export.json",
    "schema3-bootstrap-wire.bin", "schema3-bootstrap-compile.log",
    "schema3-bootstrap-result.log", "schema3-bootstrap-consumer-test.log",
    "schema3-bootstrap.consumed.retained.json",
]
PHASE_FAILURES = [
    "missing_wire", "missing_metadata", "stale_metadata", "mutated_wire",
    "duplicate_metadata_keys", "consumer_failure", "consumer_process_error",
    "missing_consume_record", "tampered_consume_record", "mutated_after_consumer",
    "wrong_stage_uuid",
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
    """Mock process seam: writes the same stage output files the real commands would.

    `target_stage` restricts the injected scenario to one stage, so main() mock
    runs can produce a stage-specific failure (and a real stage-1 pass) instead
    of failing the earliest stage.
    """

    def __init__(self, root: Path, scenario: str, module, clock=None, target_stage=None):
        self.root = root
        self.scenario = scenario
        self.module = module
        self.clock = clock or ProducerClock()
        self.target_stage = target_stage
        self.commands = []

    def scenario_applies(self, stage):
        return self.target_stage is None or self.target_stage == stage

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
        for stage, spec in STAGES.items():
            if name == spec["executable"]:
                return self.producer(stage)
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

    def producer_metadata(self, stage, digest):
        spec = STAGES[stage]
        return {
            "schema": "pili.account.schema3-export.v1",
            "sourceSHA": MAIN_SHA,
            "workflowSHA": None,
            "transactionID": spec["transaction"],
            "envelopeSchemaVersion": 3,
            "envelopeByteCount": len(MOCK_WIRE),
            "envelopeSHA256": digest,
            "wireFileName": spec["wire"],
        }

    def producer(self, stage):
        spec = STAGES[stage]
        digest = hashlib.sha256(MOCK_WIRE).hexdigest()
        metadata = self.producer_metadata(stage, digest)
        if self.scenario == "stage2_tampers_retained" and stage == "bootstrap":
            (self.root / STAGES["export"]["retained"]).write_bytes(b"tampered-retained")
        if not self.scenario_applies(stage):
            (self.root / spec["wire"]).write_bytes(MOCK_WIRE)
            (self.root / spec["metadata"]).write_text(json.dumps(metadata), encoding="utf-8")
            return spec["check_line"]
        if self.scenario == "missing_wire":
            (self.root / spec["metadata"]).write_text(json.dumps(metadata), encoding="utf-8")
            return spec["check_line"]
        if self.scenario == "missing_metadata":
            (self.root / spec["wire"]).write_bytes(MOCK_WIRE)
            return spec["check_line"]
        if self.scenario == "duplicate_metadata_keys":
            (self.root / spec["wire"]).write_bytes(MOCK_WIRE)
            text = ('{"schema":"pili.account.schema3-export.v1",'
                    '"sourceSHA":"%s","sourceSHA":"%s","workflowSHA":null,'
                    '"transactionID":"%s","envelopeSchemaVersion":3,'
                    '"envelopeByteCount":%d,"envelopeSHA256":"%s",'
                    '"wireFileName":"%s"}'
                    % (MAIN_SHA, MAIN_SHA, spec["transaction"], len(MOCK_WIRE), digest,
                       spec["wire"]))
            (self.root / spec["metadata"]).write_text(text, encoding="utf-8")
            return spec["check_line"]
        if self.scenario == "stale_metadata":
            metadata["sourceSHA"] = "b" * 40
        if self.scenario == "mutated_wire":
            (self.root / spec["wire"]).write_bytes(b"tampered")
        else:
            (self.root / spec["wire"]).write_bytes(MOCK_WIRE)
        (self.root / spec["metadata"]).write_text(json.dumps(metadata), encoding="utf-8")
        return spec["check_line"]

    def consumer(self, joined):
        assert "--dart-define=NATIVE_ACCOUNT_SCHEMA3_EXPORT=" in joined
        assert "--dart-define=NATIVE_ACCOUNT_SCHEMA3_SOURCE=" in joined
        assert "live-memory.json" in joined
        assert "test/services/native_accounts/native_account_schema3_export_consumption_test.dart" in joined
        match = re.search(r"--dart-define=NATIVE_ACCOUNT_SCHEMA3_EXPORT=(\S+)", joined)
        metadata_path = Path(match.group(1))
        stage = "bootstrap" if "bootstrap" in metadata_path.name else "export"
        spec = STAGES[stage]
        if self.scenario == "consumer_process_error" and self.scenario_applies(stage):
            raise RuntimeError(f"{spec['consumer_test_log']}: command failed (1)")
        if self.scenario == "consumer_failure" and self.scenario_applies(stage):
            return "00:00 +5 -1: Some tests failed.\n"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        digest = metadata["envelopeSHA256"]
        if self.scenario == "mutated_after_consumer" and self.scenario_applies(stage):
            (self.root / metadata["wireFileName"]).write_bytes(b"tampered-after-consumer")
        if self.scenario == "tampered_consume_record" and self.scenario_applies(stage):
            digest = "0" * 64
        transaction = metadata["transactionID"]
        if self.scenario == "wrong_stage_uuid" and self.scenario_applies(stage):
            other = "bootstrap" if stage == "export" else "export"
            transaction = STAGES[other]["transaction"]
        if not (self.scenario == "missing_consume_record" and self.scenario_applies(stage)):
            consumed = {
                "schema": "pili.account.schema3-export.consumed.v1",
                "transactionID": transaction,
                "envelopeSHA256": digest,
                "envelopeByteCount": metadata["envelopeByteCount"],
            }
            (self.root / "schema3-export-consumed.json").write_text(
                json.dumps(consumed), encoding="utf-8")
        return "00:00 +6: All tests passed!\n"


def stage_kwargs(module, stage):
    spec = STAGES[stage]
    return {
        "stage": stage,
        "source_sha": MAIN_SHA,
        "workflow_sha": None,
        "sources": module.EXPORT_SOURCES if stage == "export" else module.BOOTSTRAP_SOURCES,
        "executable_name": spec["executable"],
        "metadata_name": spec["metadata"],
        "wire_name": spec["wire"],
        "expected_wire_name": spec["wire"],
        "compile_log": spec["compile_log"],
        "result_log": spec["result_log"],
        "consumer_test_log": spec["consumer_test_log"],
        "retained_consumed_name": spec["retained"],
        "minimum_checks": (module.MINIMUM_EXPORT_CHECKS if stage == "export"
                           else module.MINIMUM_BOOTSTRAP_CHECKS),
        "consumer_tests": 6,
        "run_analyze": stage == "export",
    }


def run_stage(module, stage, scenario, workflow_sha=None):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        fake = FakePipeline(root, scenario, module, target_stage=stage)
        previous_output = module.OUTPUT
        previous_run = module.run
        module.OUTPUT = root
        module.run = fake.run
        try:
            kwargs = stage_kwargs(module, stage)
            kwargs["workflow_sha"] = workflow_sha
            evidence = module.verify_crossruntime_stage(**kwargs)
            fake.retained_exists = (root / STAGES[stage]["retained"]).is_file()
            fake.retained_digest = evidence["retainedConsumedSHA256"]
            fake.scratch_exists = (root / "schema3-export-consumed.json").exists()
        finally:
            module.OUTPUT = previous_output
            module.run = previous_run
        return evidence, fake


def run_main(module, scenario, clock=None, target_stage=None):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        fake = FakePipeline(root, scenario, module, clock=clock, target_stage=target_stage)
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


def check_stage_success(module):
    for stage in ("export", "bootstrap"):
        spec = STAGES[stage]
        evidence, fake = run_stage(module, stage, "happy")
        assert evidence["stage"] == stage
        assert evidence["transactionID"] == spec["transaction"]
        assert evidence["wireByteCount"] == len(MOCK_WIRE)
        assert evidence["consumerTests"] == 6
        assert evidence["checks"] == spec["checks"]
        assert evidence["retainedConsumedName"] == spec["retained"]
        assert len(evidence["metadataSHA256"]) == 64
        assert len(evidence["wireSHA256"]) == 64
        assert len(evidence["retainedConsumedSHA256"]) == 64
        assert fake.retained_exists, f"{stage} stage did not retain its consumption record"
        assert not fake.scratch_exists, \
            f"{stage} stage left the scratch consumer record behind"
        logs = [log for _, log in fake.commands]
        for log in (spec["compile_log"], spec["result_log"], spec["consumer_test_log"]):
            assert log in logs, f"{stage} stage did not run {log}"
        assert ("schema3-export-consumer-analyze.log" in logs) == (stage == "export"), \
            f"{stage} stage analyze wiring is wrong"


def expect_failure(module, stage, scenario):
    try:
        run_stage(module, stage, scenario)
    except (RuntimeError, ValueError):
        return
    raise AssertionError(f"{stage} stage did not fail closed on {scenario}")


def check_stage_wrong_workflow(module):
    for stage in ("export", "bootstrap"):
        try:
            run_stage(module, stage, "happy", workflow_sha="c" * 40)
        except RuntimeError:
            continue
        raise AssertionError(f"{stage} stage accepted a mismatched workflow SHA")


def check_main_success(module):
    # Two different clock bases: the deterministic producer window must hold on
    # any boundary, without host clock granularity involvement.
    for clock in (ProducerClock(0, 5), ProducerClock(1_700_000_000_000_000, 7)):
        exit_code, summary, fake = run_main(module, "happy", clock=clock)
        assert exit_code == 0, summary.get("reason")
        assert summary["status"] == "passed"
        assert summary["sourceSHA"] == MAIN_SHA
        export = summary["schema3Export"]
        bootstrap = summary["schema3Bootstrap"]
        assert export["checks"] == STAGES["export"]["checks"]
        assert bootstrap["checks"] == STAGES["bootstrap"]["checks"]
        assert export["consumerTests"] == 6 and bootstrap["consumerTests"] == 6
        assert export["transactionID"] == MOCK_TRANSACTION
        assert bootstrap["transactionID"] == MOCK_BOOTSTRAP_TRANSACTION
        assert export["retainedConsumedName"] == STAGES["export"]["retained"]
        assert bootstrap["retainedConsumedName"] == STAGES["bootstrap"]["retained"]
        assert len(export["wireSHA256"]) == 64 and len(bootstrap["wireSHA256"]) == 64
        commands = [" ".join(command) for command, _ in fake.commands]
        assert any("check-native-account-envelope-export" in command for command in commands), \
            "main() never reached the cross-runtime export stage"
        assert any("check-native-account-envelope-bootstrap" in command for command in commands), \
            "main() never reached the cross-runtime bootstrap stage"
        consumer_runs = [command for command in commands
                         if command.startswith("flutter test")
                         and "native_account_schema3_export_consumption_test.dart" in command]
        assert len(consumer_runs) == 2, \
            "both cross-runtime stages must run the real consumer independently"


def check_main_failure(module, scenario, expected_reason, expected_drivers, target_stage=None):
    exit_code, summary, fake = run_main(module, scenario, target_stage=target_stage)
    assert exit_code == 1, "a failed stage must exit non-zero"
    assert summary["status"] == "failed"
    assert summary.get("reason") == expected_reason, \
        f"failed summary must record the intended cause, got {summary.get('reason')!r}"
    commands = [" ".join(command) for command, _ in fake.commands]
    for driver in expected_drivers:
        assert any(driver in command for command in commands), \
            f"the {driver} stage never ran; an earlier failure cannot prove this negative path"
    assert any("test/utils/accounts/" in command for command in commands), \
        "the producer phase never ran before the intended failure"


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
    stage_calls = []
    passed_lines = []
    for node in ast.walk(main):
        if not isinstance(node, ast.Call):
            continue
        if isinstance(node.func, ast.Name) and node.func.id == "verify_crossruntime_stage":
            stage = None
            for keyword in node.keywords:
                if keyword.arg == "stage" and isinstance(keyword.value, ast.Constant):
                    stage = keyword.value.value
            stage_calls.append((node.lineno, stage))
        if isinstance(node.func, ast.Attribute) and node.func.attr == "update":
            for keyword in node.keywords:
                if (keyword.arg == "status" and isinstance(keyword.value, ast.Constant)
                        and keyword.value.value == "passed"):
                    passed_lines.append(node.lineno)
    assert {stage for _, stage in stage_calls} == {"export", "bootstrap"}, \
        "main() must run both crossruntime stages through the shared helper"
    assert passed_lines, "main() no longer writes a passed summary"
    assert max(line for line, _ in stage_calls) < min(passed_lines), \
        "both cross-runtime stages must run before the passed summary"
    helper = next(node for node in tree.body
                  if isinstance(node, ast.FunctionDef) and node.name == "verify_crossruntime_stage")
    arguments = {argument.arg for argument in helper.args.kwonlyargs}
    for name in ("stage", "source_sha", "workflow_sha", "sources", "minimum_checks", "run_analyze"):
        assert name in arguments, f"stage helper is missing the explicit {name} input"
    for symbol in ("EXPORT_SOURCES", "BOOTSTRAP_SOURCES", "EXPORT_CONSUMER", "EXPORT_QA",
                   "MINIMUM_EXPORT_CHECKS", "MINIMUM_BOOTSTRAP_CHECKS", "CROSSRUNTIME_CONSUMED"):
        assert symbol in source, f"source ledger is missing {symbol}"
    assert "os.replace(consumed_path, retained)" in source, \
        "stage helper does not retain its consumption record with a controlled rename"
    workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
    assert "python3 tool/check_native_account_envelopes.py" in workflow
    assert "ACCOUNT_ENVELOPE_OUTCOME: ${{ steps.group-account-envelope.outcome }}" in workflow
    assert "build/native-account-envelope-check/*.bin" in workflow
    assert '"test/services/native_accounts/**"' in workflow
    assert workflow.count('"tool/check_native_account_envelope_bootstrap*"') == 2, \
        "both workflow trigger sections must cover the bootstrap driver"


def check_driver_static_bindings():
    """Static source checks for the two drivers. Source-level only: not Swift
    execution evidence."""
    export_source = EXPORT_DRIVER_PATH.read_text(encoding="utf-8")
    match = re.search(
        r"private static func remintedManifest\(_ bytes: Data\) throws -> Data \{(?P<body>.*?)\n  \}",
        export_source, re.S)
    assert match is not None, "remintedManifest function body not found"
    body = match.group("body")
    assert 'object["transactionID"] = UUID().uuidString.lowercased()' in body, \
        "changed-manifest fixture must remint the transaction ID"
    assert "byteCount" not in body and "sha256" not in body, \
        "changed-manifest fixture must be a pointer-only mutation"
    for label in ("changed-manifest cancel preserves the exact independently expected fixture mutation",
                  "cleanup restores the original vault bytes"):
        assert label in export_source, f"changed-manifest row is missing its expected-state label: {label}"
    bootstrap_source = BOOTSTRAP_DRIVER_PATH.read_text(encoding="utf-8")
    assert "PiliAccountShadowUnresolvedWriteKind.bootstrap.rawValue" in bootstrap_source, \
        "bootstrap driver must assert the transaction enum literal"
    assert "PiliAccountEnvelopeRecoveryJournal.bootstrapKind" in bootstrap_source, \
        "bootstrap driver must bind the staging lower-layer constant"
    assert "private struct FixtureManifest: Codable" in bootstrap_source, \
        "bootstrap driver must independently encode the actual Codable manifest wire"
    assert "encoder.encode(FixtureManifest(" in bootstrap_source, \
        "the manifest byte oracle must encode the actual wire representation, not lowercase JSON"
    assert '"transactionID": transactionID.uuidString.lowercased()' not in bootstrap_source, \
        "the manifest oracle must not lowercase the UUID serialization"
    assert "writeAttempts == 4 && removeAttempts == 1" in bootstrap_source, \
        "the clean/recovered commit rows must include the verified journal removal"
    assert "PiliAccountShadowTransactionError.unresolvedPublication" in bootstrap_source, \
        "the cold-owner row must assert the exact owner-side fence error"
    assert "expectAssociationRejection" in bootstrap_source \
        and "association: record projection" in bootstrap_source, \
        "association negatives must use exact typed reasons including the generation row"
    assert "recordCommitThenThrow" in bootstrap_source and "failDescriptorReadAt" in bootstrap_source, \
        "candidate after-commit IO-throw and descriptor read IO seams must exist"
    assert "descriptorCommitThenThrow" in bootstrap_source, \
        "the descriptor write commit-then-throw seam must exist for the per-phase matrix"
    for label in ("record-nil-collision-cancel", "descriptor-nil-collision-cancel"):
        assert label in bootstrap_source, \
            f"the successful-NIL collision-read cancellation row is missing: {label}"
    assert "pausePointerReadAt" in bootstrap_source and "pauseRecordReadAt" in bootstrap_source \
        and "pauseDescriptorReadAt" in bootstrap_source, \
        "refusing-result cancellation rows must control pointer/record/descriptor read pauses"
    assert "failJournalRemoves(true)" in bootstrap_source and "failJournalReadAt(3)" in bootstrap_source, \
        "bootstrap driver must distinguish a refused remove from a committed-remove verification failure"
    assert "honest state: the committed removal leaves no retained journal bytes" in bootstrap_source, \
        "bootstrap driver must assert the actual absence after a committed remove"
    assert "failJournalReadsTyped" in bootstrap_source and "forged-kind" in bootstrap_source, \
        "bootstrap driver must cover unreadable and forged-kind journal evidence"


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

    attempt("both stage happy mocks return their exact evidence",
            lambda: check_stage_success(module))
    for stage in ("export", "bootstrap"):
        for scenario in PHASE_FAILURES:
            attempt(f"{stage} stage fails closed on {scenario}",
                    lambda stage=stage, scenario=scenario: expect_failure(module, stage, scenario))
    attempt("both stages reject a mismatched workflow SHA",
            lambda: check_stage_wrong_workflow(module))
    attempt("full main() mock passes with both stage evidences",
            lambda: check_main_success(module))
    attempt("full main() mock fails summary/exit1 on a stale export",
            lambda: check_main_failure(
                module, "stale_metadata", STALE_EXPORT_REASON,
                ["check-native-account-envelope-export"], target_stage="export"))
    attempt("full main() mock fails summary/exit1 on a stage-2 stale bootstrap",
            lambda: check_main_failure(
                module, "stale_metadata", STALE_BOOTSTRAP_REASON,
                ["check-native-account-envelope-export", "check-native-account-envelope-bootstrap"],
                target_stage="bootstrap"))
    attempt("full main() mock fails the post-ALL recheck on tampered stage-1 retained record",
            lambda: check_main_failure(
                module, "stage2_tampers_retained", TAMPERED_RETAINED_REASON,
                ["check-native-account-envelope-export", "check-native-account-envelope-bootstrap"]))
    attempt("static pipeline/workflow wiring", check_static_wiring)
    attempt("driver static bindings", check_driver_static_bindings)
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
          "the mock '126/181 native ... checks passed' lines are MOCK subprocess output, not "
          "Swift execution counts")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
