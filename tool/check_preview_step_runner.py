"""Local negative/success QA for preview_step_runner (not simulator evidence).

Run: python3 tool/check_preview_step_runner.py

Exercises the streaming step runner on this machine only: exact success,
preserved nonzero failure, bounded timeout cleanup, injected cancellation,
busy/backlogged output, early-EOF live children, EOF/cancel races, the
non-masking bounded-cleanup helper, and (on POSIX only) an ignoring-SIGTERM
grandchild after leader exit. It never launches a simulator, XCTest or the
preview app, and its output is local mocked-QA evidence, not CI or device
evidence. The POSIX case is explicitly skipped (and labelled) elsewhere.
"""
import os
import sys
import tempfile
import threading
import time
from pathlib import Path

import preview_step_runner as runner

CHECKS = []


def check(name, condition, detail=''):
    CHECKS.append((name, bool(condition)))
    print(f'{"PASS" if condition else "FAIL"} {name}{(" " + detail) if detail else ""}', flush=True)


def child(source):
    return [sys.executable, '-u', '-c', source]


BUSY_SOURCE = (
    "import sys, time\n"
    "end = time.time() + 1.2\n"
    "while time.time() < end:\n"
    "    print('busy-output-line')\n"
    "    time.sleep(0.002)\n"
    "sys.exit(0)\n"
)


def eof_then_sleep(seconds, code):
    return (
        "import os, sys, time\n"
        "sys.stdout.write('stream-open\\n')\n"
        "sys.stdout.flush()\n"
        "os.close(1)\n"
        f"time.sleep({seconds})\n"
        f"sys.exit({code})\n"
    )


def main():
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp)
        phases = runner.PhaseLog(out / 'phases.log')

        log = out / 'success.log'
        code = runner.run_streaming(
            child("print('hello-step'); print('bye-step')"), log, phases, 'success-case')
        text = log.read_text(encoding='utf-8')
        check('success exit code preserved', code == 0, f'code={code}')
        check('success output streamed to log', 'hello-step' in text and 'bye-step' in text)
        started = phases.path.read_text(encoding='utf-8')
        check('success phase launch recorded', 'success-case: launch' in started)
        check('success phase exit recorded', 'success-case: exit 0' in started)

        log = out / 'nonzero.log'
        code = runner.run_streaming(
            child("print('failing-step'); import sys; sys.exit(7)"), log, phases, 'nonzero-case')
        check('nonzero exit code preserved (not masked)', code == 7, f'code={code}')
        check('nonzero output flushed', 'failing-step' in log.read_text(encoding='utf-8'))
        check('nonzero phase exit recorded', 'nonzero-case: exit 7' in phases.path.read_text(encoding='utf-8'))

        marker = out / 'timeout-marker'
        log = out / 'timeout.log'
        timed_out = False
        try:
            runner.run_streaming(
                child(f"import time, pathlib; print('sleeping'); time.sleep(2); "
                      f"pathlib.Path(r'{marker}').write_text('alive'); time.sleep(600)"),
                log, phases, 'timeout-case', timeout=1.0)
        except runner.StepTimeout:
            timed_out = True
        check('timeout raised StepTimeout and preserved failure', timed_out)
        check('timeout output flushed before stop', 'sleeping' in log.read_text(encoding='utf-8'))
        check('timeout phase recorded', 'timeout-case: timeout' in phases.path.read_text(encoding='utf-8'))
        time.sleep(2.5)
        check('timed-out child was actually stopped (no marker)', not marker.exists())

        marker = out / 'cancel-marker'
        log = out / 'cancel.log'
        cancel = threading.Event()
        timer = threading.Timer(1.0, cancel.set)
        timer.start()
        cancelled = False
        try:
            runner.run_streaming(
                child(f"import time, pathlib; print('waiting'); time.sleep(2); "
                      f"pathlib.Path(r'{marker}').write_text('alive'); time.sleep(600)"),
                log, phases, 'cancel-case', cancel_event=cancel)
        except runner.StepCancelled:
            cancelled = True
        finally:
            timer.cancel()
        check('cancel raised StepCancelled and preserved failure', cancelled)
        check('cancel output flushed before stop', 'waiting' in log.read_text(encoding='utf-8'))
        check('cancel phase recorded', 'cancel-case: cancelled' in phases.path.read_text(encoding='utf-8'))
        time.sleep(2.5)
        check('cancelled child was actually stopped (no marker)', not marker.exists())

        log = out / 'busy-timeout.log'
        busy_timed_out = False
        try:
            runner.run_streaming(child(BUSY_SOURCE), log, phases, 'busy-timeout-case', timeout=0.05)
        except runner.StepTimeout:
            busy_timed_out = True
        check('busy output cannot suppress the deadline (StepTimeout)', busy_timed_out)
        check('busy-timeout phase recorded',
              'busy-timeout-case: timeout' in phases.path.read_text(encoding='utf-8'))

        log = out / 'busy-cancel.log'
        cancel = threading.Event()
        timer = threading.Timer(0.05, cancel.set)
        timer.start()
        busy_cancelled = False
        try:
            runner.run_streaming(child(BUSY_SOURCE), log, phases, 'busy-cancel-case', cancel_event=cancel)
        except runner.StepCancelled:
            busy_cancelled = True
        finally:
            timer.cancel()
        check('busy output cannot suppress cancellation (StepCancelled)', busy_cancelled)
        check('busy-cancel phase recorded',
              'busy-cancel-case: cancelled' in phases.path.read_text(encoding='utf-8'))

        log = out / 'eof-timeout.log'
        eof_timed_out = False
        try:
            runner.run_streaming(child(eof_then_sleep(0.8, 0)), log, phases,
                                 'eof-timeout-case', timeout=0.1)
        except runner.StepTimeout:
            eof_timed_out = True
        check('EOF on a live child is not completion (StepTimeout)', eof_timed_out)
        check('eof-timeout phase recorded',
              'eof-timeout-case: timeout' in phases.path.read_text(encoding='utf-8'))

        log = out / 'eof-returncode.log'
        code = runner.run_streaming(child(eof_then_sleep(0.3, 3)), log, phases, 'eof-returncode-case')
        check('EOF-live child returns its real exit code (not early success)', code == 3, f'code={code}')
        check('eof-returncode phase recorded',
              'eof-returncode-case: exit 3' in phases.path.read_text(encoding='utf-8'))

        log = out / 'eof-cancel.log'
        cancel = threading.Event()
        timer = threading.Timer(0.05, cancel.set)
        timer.start()
        eof_cancelled = False
        try:
            runner.run_streaming(child(eof_then_sleep(1.0, 0)), log, phases,
                                 'eof-cancel-case', cancel_event=cancel)
        except runner.StepCancelled:
            eof_cancelled = True
        finally:
            timer.cancel()
        check('cancel on EOF-live child cannot return success (StepCancelled)', eof_cancelled)
        check('eof-cancel phase recorded',
              'eof-cancel-case: cancelled' in phases.path.read_text(encoding='utf-8'))

        cleanup_code = runner.run_bounded_cleanup(child("print('cleanup-ok')"), phases, 'cleanup-success')
        check('bounded cleanup success returns 0', cleanup_code == 0, f'code={cleanup_code}')
        cleanup_code = runner.run_bounded_cleanup(child("import sys; sys.exit(5)"), phases, 'cleanup-nonzero')
        check('bounded cleanup nonzero code preserved', cleanup_code == 5, f'code={cleanup_code}')
        cleanup_code = runner.run_bounded_cleanup(
            [str(out / 'missing-executable-fixture')], phases, 'cleanup-raising')
        check('bounded cleanup failure returns None without raising', cleanup_code is None)
        cleanup_phases = phases.path.read_text(encoding='utf-8')
        check('bounded cleanup outcomes recorded',
              'cleanup-success: exit 0' in cleanup_phases
              and 'cleanup-nonzero: exit 5' in cleanup_phases
              and 'cleanup-raising: failed' in cleanup_phases)

        if os.name == 'posix':
            marker = out / 'posix-descendant-marker'
            grandchild = (
                "import pathlib, signal, sys, time\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "time.sleep(3)\n"
                "pathlib.Path(sys.argv[1]).write_text('alive')\n"
                "time.sleep(30)\n"
            )
            parent = (
                "import subprocess, sys\n"
                f"subprocess.Popen([sys.executable, '-c', {grandchild!r}, {str(marker)!r}])\n"
                "sys.exit(0)\n"
            )
            code = runner.run_streaming(child(parent), out / 'posix-descendant.log', phases,
                                        'posix-descendant-case', term_grace=1.0)
            check('posix descendant case leader exit preserved', code == 0, f'code={code}')
            time.sleep(3.5)
            check('ignoring-TERM descendant cleaned up after leader exit (no marker)',
                  not marker.exists())
        else:
            print('SKIP POSIX descendant cleanup case (requires POSIX); '
                  'not counted as a pass', flush=True)

    failed = [name for name, ok in CHECKS if not ok]
    print(f'{len(CHECKS) - len(failed)}/{len(CHECKS)} local runner QA checks passed '
          '(local mocked QA, not simulator evidence)', flush=True)
    if failed:
        raise SystemExit(f'failed checks: {failed}')


if __name__ == '__main__':
    main()
