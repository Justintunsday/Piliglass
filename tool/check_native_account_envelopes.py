"""Fresh actual Dart full-account observations against production Swift codec.

Never compile ignored DTO/parser substitutes or accept pre-existing goldens after
a producer failure. Every fresh golden is hashed before Native compilation, again
before execution and again after execution; the contract sources must match the
checked-out HEAD while unrelated build patches remain untouched.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/native-account-envelope-check"
PRODUCERS = [
    "test/utils/accounts/native_account_envelope_export_test.dart",
    "test/utils/accounts/native_account_envelope_cold_export_test.dart",
]
ANALYSIS = [
    "lib/utils/accounts.dart",
    "lib/utils/accounts/account.dart",
    "lib/utils/accounts/account_request_state.dart",
    "lib/utils/accounts/account_live_memory_shadow.dart",
    "lib/services/native_accounts/",
    "test/utils/accounts/account_test_storage.dart",
    "test/utils/accounts/native_account_envelope_fixtures.dart",
    *PRODUCERS,
]
# These are the intended production integration paths, not ignored draft files.
# Jar parser/value sharing and the inout ledger remain in the existing jar sources.
SOURCES = [
    "ios/Runner/Native/Domain/Accounts/PiliAccountRepository.swift",
    "ios/Runner/Native/Domain/Accounts/PiliOrderedCookieArchive.swift",
    "ios/Runner/Native/Data/Accounts/PiliOrderedCookieArchiveCodec.swift",
    "ios/Runner/Native/Domain/Accounts/PiliAccountLiveMemoryShadow.swift",
    "ios/Runner/Native/Data/Accounts/PiliAccountLiveMemoryShadowCodec.swift",
    "tool/check_native_account_envelopes.swift",
]
# Durable shadow publication is a separate contract phase. It reuses the same
# actual Dart goldens but adds the isolated Keychain vault and fault matrix.
STAGING_SOURCES = [
    "ios/Runner/Native/Domain/Accounts/PiliAccountRepository.swift",
    "ios/Runner/Native/Domain/Accounts/PiliOrderedCookieArchive.swift",
    "ios/Runner/Native/Data/Accounts/PiliOrderedCookieArchiveCodec.swift",
    "ios/Runner/Native/Domain/Accounts/PiliAccountLiveMemoryShadow.swift",
    "ios/Runner/Native/Data/Accounts/PiliAccountLiveMemoryShadowCodec.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliAccountSecretStore.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliAccountEnvelopeStagingStore.swift",
    "tool/check_native_account_envelope_staging.swift",
]
# Durable single-account Cookie transactions over the shadow candidate. The
# production reducer and parser own mutation semantics; this phase verifies the
# transaction/publication plumbing and cumulative envelope revalidation.
TRANSACTION_SOURCES = [
    "ios/Runner/Native/Domain/Accounts/PiliAccountRepository.swift",
    "ios/Runner/Native/Domain/Accounts/PiliOrderedCookieArchive.swift",
    "ios/Runner/Native/Data/Accounts/PiliOrderedCookieArchiveCodec.swift",
    "ios/Runner/Native/Domain/Accounts/PiliAccountLiveMemoryShadow.swift",
    "ios/Runner/Native/Data/Accounts/PiliAccountLiveMemoryShadowCodec.swift",
    "ios/Runner/Native/Data/Accounts/PiliNativeOrderedCookieReducer.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliNativeCookieParser.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliAccountSecretStore.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliAccountEnvelopeStagingStore.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliAccountEnvelopeTransactionStore.swift",
    "tool/check_native_account_envelope_transaction.swift",
]
# Durable authority marker and two-phase handoff/revert. Native-only machinery
# with real Keychain crash/fault recovery; no Dart runtime caller is installed.
AUTHORITY_SOURCES = [
    "ios/Runner/Native/Domain/Accounts/PiliAccountRepository.swift",
    "ios/Runner/Native/Domain/Accounts/PiliOrderedCookieArchive.swift",
    "ios/Runner/Native/Data/Accounts/PiliOrderedCookieArchiveCodec.swift",
    "ios/Runner/Native/Domain/Accounts/PiliAccountLiveMemoryShadow.swift",
    "ios/Runner/Native/Data/Accounts/PiliAccountLiveMemoryShadowCodec.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliAccountSecretStore.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliAccountEnvelopeStagingStore.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliAccountAuthorityMarkerStore.swift",
    "ios/Runner/Native/Persistence/Accounts/PiliAccountAuthorityCoordinator.swift",
    "tool/check_native_account_authority.swift",
]
LIVE_IDS = [
    "anonymous-empty-jar",
    "stored-10-2-owner-2-10",
    "same-key-replacement-owner-10-2",
    "distinct-raw-02-and-2-equal-mid",
    "zero-and-negative-login-mid",
    "four-effective-purposes",
    "temporary-heartbeat-anonymous-history-main",
    "anonymous-persisted-purposes",
    "raw-utf16-full-attributes-nullable-credentials",
]
COLD_IDS = ["actual-hive-reopen-before-refresh"]
MINIMUM_NEGATIVE_CASES = 43
# Include the actual legacy adapter/lifecycle inputs and locked dependencies,
# not only the files explicitly named in the focused analyzer command.
CONTRACT_INPUTS = [
    "pubspec.yaml", "pubspec.lock", "lib/utils/accounts/",
    "lib/utils/storage.dart", "lib/utils/storage_pref.dart", "lib/utils/id_utils.dart",
    "lib/utils/login_utils.dart", "lib/http/init.dart", "lib/models/common/account_type.dart",
]


def source_hashes():
    paths = {ROOT / path for path in [*SOURCES, *STAGING_SOURCES, *TRANSACTION_SOURCES,
                                      *AUTHORITY_SOURCES, *PRODUCERS, *ANALYSIS, *CONTRACT_INPUTS]}
    files = set()
    for path in paths:
        if path.is_dir():
            files.update(path.rglob("*.dart"))
        elif path.is_file():
            files.add(path)
        else:
            raise RuntimeError(f"Analysis/source path absent: {path.relative_to(ROOT)}")
    files.add(Path(__file__).resolve())
    return {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(files)}


def clean_contract_sources(log):
    # Existing CI version/Geetest/material/cupertino preparation legitimately
    # patches unrelated lib/pubspec/Runner inputs. Require only this contract's
    # analyzed/compiled sources to match HEAD; hash the actual resolved inputs
    # separately, including those already prepared by the build workflow.
    paths = sorted({*SOURCES, *STAGING_SOURCES, *TRANSACTION_SOURCES, *AUTHORITY_SOURCES,
                    *PRODUCERS, *ANALYSIS,
                    Path(__file__).resolve().relative_to(ROOT).as_posix()})
    run(["git", "diff", "--quiet", "HEAD", "--", *paths], log)


def run(command, log, timeout=180):
    try:
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        def partial(value):
            return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else (value or "")
        (OUTPUT / log).write_text(
            shlex.join(command) + "\n" + partial(error.stdout) + partial(error.stderr)
            + f"\nCommand timed out after {timeout} seconds\n", encoding="utf-8")
        raise
    output = result.stdout + result.stderr
    (OUTPUT / log).write_text(shlex.join(command) + "\n" + output, encoding="utf-8")
    if result.returncode:
        print(output[-12000:])
        raise RuntimeError(f"{log}: command failed ({result.returncode})")
    return output


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise RuntimeError(f"Duplicate actual fixture field: {key}")
        result[key] = value
    return result


def fixture(path, required_ids, producer_window):
    data = path.read_bytes()
    # Python int preserves original integer precision. Swift also consumes the
    # original file bytes; no Python JSON round-trip is passed as its oracle.
    root = json.loads(data, object_pairs_hook=strict_object)
    if (not isinstance(root, dict) or type(root.get("schemaVersion")) is not int or root["schemaVersion"] != 1
            or root.get("runtimeCutover") is not False
            or root.get("durableIdentityConfigured") is not False):
        raise RuntimeError(f"Bad runtime/source flags in fresh {path.name}")
    expected_source = ("actual Hive type8/type9 write-close-reopen / production capture service"
                       if path.name == "hive-reopened.json" else
                       "actual Accounts / real Hive / production live-memory capture service")
    if root.get("source") != expected_source:
        raise RuntimeError(f"Actual producer source label missing in {path.name}")
    clock = root.get("clockPolicy", {})
    if (not isinstance(clock, dict) or clock.get("kind") != "actualDartDateTimeNow" or clock.get("injectedClock") is not False
            or clock.get("exactBoundaryProof") is not False):
        raise RuntimeError(f"Injected/unsupported clock evidence in {path.name}")
    cases = root.get("cases")
    if (not isinstance(cases, list) or not all(isinstance(item, dict) for item in cases)
            or [item.get("id") for item in cases] != required_ids):
        raise RuntimeError(f"Partial/missing/excess actual cases in {path.name}")
    for item in cases:
        envelope = item.get("envelope")
        if (not isinstance(envelope, dict) or type(envelope.get("schemaVersion")) is not int
                or envelope["schemaVersion"] != 2 or envelope.get("scope") != "coherentLiveMemoryShadow"
                or envelope.get("identityScope") != "captureLocal"):
            raise RuntimeError("Actual production capture payload missing")
        for flag in ["durableIdentityConfigured", "durabilityVerified", "authoritySwitchAllowed", "nativeWritesAllowed"]:
            if envelope.get(flag) is not False:
                raise RuntimeError(f"Production capture enabled {flag}")
        started, finished = item.get("captureStartedMicroseconds"), item.get("captureFinishedMicroseconds")
        if type(started) is not int or type(finished) is not int or not 0 <= started <= finished:
            raise RuntimeError("Missing actual ordered wall-clock capture window")
        if not producer_window[0] <= started <= finished <= producer_window[1]:
            raise RuntimeError("Observation was not captured inside this fresh actual producer run")
    if path.name == "hive-reopened.json":
        before = root.get("preHiveJarObservations")
        if root.get("crossRestartStampContinuity") is not False or not isinstance(before, list) or len(before) != 2:
            raise RuntimeError("Actual cold/pre-Hive source boundary missing")
    return len(cases), hashlib.sha256(data).hexdigest()


def verify_golden_hashes(expected):
    current = {name: hashlib.sha256((OUTPUT / name).read_bytes()).hexdigest() for name in expected}
    if current != expected:
        raise RuntimeError("Fresh actual Dart golden bytes changed during Native verification")


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = {
        "status": "failed", "platform": sys.platform, "runtimeEnabled": False,
        "scope": "full account capture-local immutable DTO/strict codec; no storage or authority",
        "durabilityVerified": False, "authoritySwitchAllowed": False,
    }
    # Reset the status before any command so a terminated run cannot inherit a
    # previous pass. Actual goldens and executable are also removed first.
    (OUTPUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    try:
        for name in ["live-memory.json", "hive-reopened.json", "check-native-account-envelopes",
                     "check-native-account-envelope-staging", "staging-compile.log", "staging-result.log",
                     "check-native-account-envelope-transaction", "transaction-compile.log",
                     "transaction-result.log", "check-native-account-authority",
                     "authority-compile.log", "authority-result.log",
                     "analyze.log", "dart-test.log", "compile.log", "result.log",
                     "source-revision.log", "source-revision-after.log",
                     "source-clean.log", "source-clean-after.log", "build-preparation-diff-names.log"]:
            (OUTPUT / name).unlink(missing_ok=True)
        if sys.platform != "darwin":
            raise RuntimeError("macOS Swift/Foundation required; skipped platforms do not verify this contract")
        source_sha = run(["git", "rev-parse", "HEAD"], "source-revision.log").strip()
        workflow_sha = os.environ.get("GITHUB_SHA")
        if not re.fullmatch(r"[0-9a-f]{40}", source_sha) or (workflow_sha and workflow_sha != source_sha):
            raise RuntimeError("Actual checkout/workflow source SHA mismatch")
        summary.update(sourceSHA=source_sha, workflowSHA=workflow_sha)
        clean_contract_sources("source-clean.log")
        summary["buildPreparationDiffNames"] = run(
            ["git", "diff", "--name-only", "HEAD"], "build-preparation-diff-names.log").splitlines()
        missing = [path for path in [*SOURCES, *PRODUCERS] if not (ROOT / path).is_file()]
        if missing:
            raise RuntimeError("Production integration missing: " + ", ".join(missing))
        source_digests = source_hashes()
        summary["sourceSHA256"] = source_digests
        run(["dart", "analyze", "--fatal-infos", *ANALYSIS], "analyze.log")
        producer_started = time.time_ns() // 1000
        output = run(["flutter", "test", "--no-pub", "--reporter", "expanded", *PRODUCERS],
                     "dart-test.log", timeout=240)
        producer_finished = time.time_ns() // 1000
        producer_window = (producer_started, producer_finished)
        summary["producerRunWindowMicroseconds"] = {"started": producer_started, "finished": producer_finished}
        tests = re.search(r"\+(\d+): All tests passed!", output)
        if not tests or int(tests[1]) != 8:
            raise RuntimeError("Actual eight producer tests did not report a complete pass")
        hashes = {}
        observations = 0
        for name, ids in [("live-memory.json", LIVE_IDS), ("hive-reopened.json", COLD_IDS)]:
            count, digest = fixture(OUTPUT / name, ids, producer_window)
            observations += count
            hashes[name] = digest
        if observations != 10:
            raise RuntimeError("Fresh actual Dart observation count is not ten")
        verify_golden_hashes(hashes)
        executable = OUTPUT / "check-native-account-envelopes"
        run(["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
             "-parse-as-library", "-o", str(executable), *(str(ROOT / path) for path in SOURCES)],
            "compile.log")
        verify_golden_hashes(hashes)
        output = run([str(executable), str(OUTPUT / "live-memory.json"), str(OUTPUT / "hive-reopened.json")],
                     "result.log", timeout=90)
        print(output, end="")
        matched = re.search(
            r"(\d+) native account envelope checks passed; actualDartObservations=(\d+) "
            r"negativeCases=(\d+) syntheticIntegerCases=1 runtimeEnabled=false", output)
        if not matched or int(matched[2]) != 10 or int(matched[3]) < MINIMUM_NEGATIVE_CASES:
            raise RuntimeError("Independent Native full-account comparison/negative evidence incomplete")
        verify_golden_hashes(hashes)
        staging = OUTPUT / "check-native-account-envelope-staging"
        run(["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
             "-parse-as-library", "-o", str(staging), *(str(ROOT / path) for path in STAGING_SOURCES)],
            "staging-compile.log")
        verify_golden_hashes(hashes)
        staging_output = run([str(staging), str(OUTPUT / "live-memory.json"), str(OUTPUT / "hive-reopened.json")],
                             "staging-result.log", timeout=90)
        print(staging_output, end="")
        staging_matched = re.search(r"(\d+) native account envelope staging checks passed", staging_output)
        if not staging_matched or int(staging_matched[1]) < 30:
            raise RuntimeError("Durable account envelope shadow publication evidence incomplete")
        verify_golden_hashes(hashes)
        transaction = OUTPUT / "check-native-account-envelope-transaction"
        run(["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
             "-parse-as-library", "-o", str(transaction), *(str(ROOT / path) for path in TRANSACTION_SOURCES)],
            "transaction-compile.log")
        verify_golden_hashes(hashes)
        transaction_output = run([str(transaction), str(OUTPUT / "live-memory.json")],
                                 "transaction-result.log", timeout=90)
        print(transaction_output, end="")
        transaction_matched = re.search(
            r"(\d+) native account envelope transaction checks passed", transaction_output)
        if not transaction_matched or int(transaction_matched[1]) < 20:
            raise RuntimeError("Durable account envelope transaction evidence incomplete")
        verify_golden_hashes(hashes)
        authority = OUTPUT / "check-native-account-authority"
        run(["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
             "-parse-as-library", "-o", str(authority), *(str(ROOT / path) for path in AUTHORITY_SOURCES)],
            "authority-compile.log")
        verify_golden_hashes(hashes)
        authority_output = run([str(authority), str(OUTPUT / "live-memory.json")],
                               "authority-result.log", timeout=90)
        print(authority_output, end="")
        authority_matched = re.search(r"(\d+) native account authority checks passed", authority_output)
        if not authority_matched or int(authority_matched[1]) < 15:
            raise RuntimeError("Durable account authority handoff/recovery evidence incomplete")
        final_sha = run(["git", "rev-parse", "HEAD"], "source-revision-after.log").strip()
        if final_sha != source_sha or source_hashes() != source_digests:
            raise RuntimeError("Production sources changed during actual Dart/Native verification")
        clean_contract_sources("source-clean-after.log")
        verify_golden_hashes(hashes)
        summary.update(status="passed", actualDartTests=8, actualDartObservations=10,
                       actualDartGoldens=2, goldenSHA256=hashes, nativeChecks=int(matched[1]),
                       negativeCases=int(matched[3]), syntheticIntegerCases=1,
                       stagingChecks=int(staging_matched[1]),
                       transactionChecks=int(transaction_matched[1]),
                       authorityChecks=int(authority_matched[1]), sourceSHA256=source_digests)
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        summary["reason"] = str(error)
        print(f"FAIL native account envelopes: {error}")
    (OUTPUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
