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


def eof_short_lived(seconds, code):
    """Close both streams, stay alive briefly (inside the read-poll window)."""
    return (
        "import os, sys, time\n"
        "os.close(1)\n"
        "os.close(2)\n"
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

        log = out / 'eof-race-timeout.log'
        race_timed_out = False
        try:
            runner.run_streaming(child(eof_short_lived(0.15, 0)), log, phases,
                                 'eof-race-timeout', timeout=0.08)
        except runner.StepTimeout:
            race_timed_out = True
        check('early-EOF short child cannot bypass the deadline (StepTimeout)', race_timed_out)
        check('eof-race-timeout phase recorded',
              'eof-race-timeout: timeout' in phases.path.read_text(encoding='utf-8'))

        log = out / 'eof-race-cancel.log'
        cancel = threading.Event()
        timer = threading.Timer(0.08, cancel.set)
        timer.start()
        race_cancelled = False
        try:
            runner.run_streaming(child(eof_short_lived(0.15, 0)), log, phases,
                                 'eof-race-cancel', cancel_event=cancel)
        except runner.StepCancelled:
            race_cancelled = True
        finally:
            timer.cancel()
        check('early-EOF short child cannot bypass cancellation (StepCancelled)', race_cancelled)
        check('eof-race-cancel phase recorded',
              'eof-race-cancel: cancelled' in phases.path.read_text(encoding='utf-8'))

        log = out / 'eof-race-returncode.log'
        code = runner.run_streaming(child(eof_short_lived(0.15, 4)), log, phases, 'eof-race-returncode')
        check('early-EOF short child keeps its exact returncode without cancel/expiry',
              code == 4, f'code={code}')
        check('eof-race-returncode phase recorded',
              'eof-race-returncode: exit 4' in phases.path.read_text(encoding='utf-8'))

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

        navigation = None
        try:
            import preview_ios_navigation as navigation_module
            navigation = navigation_module
        except Exception as error:  # pragma: no cover - platform dependent
            print(f'SKIP navigation integration cases (import failed: {error.__class__.__name__}); '
                  'not counted as a pass', flush=True)
        if navigation is not None:
            result = out / 'navigation-result.xcresult'
            result.mkdir()
            code = navigation.run_navigation(lambda: 0, result, phases,
                                             export_command=child("print('export-ok')"),
                                             export_timeout=5)
            check('navigation integration success returns normally', code == 0, f'code={code}')
            try:
                navigation.run_navigation(lambda: 2, result, phases,
                                          export_command=[str(out / 'missing-export-fixture')],
                                          export_timeout=5)
                check('navigation integration nonzero raises SystemExit with export failure',
                      False, 'no SystemExit')
            except SystemExit as exit_error:
                check('navigation integration nonzero raises SystemExit with export failure',
                      exit_error.code == 2, f'code={exit_error.code}')
            try:
                navigation.run_navigation(lambda: 3, result, phases,
                                          export_command=child("import time; time.sleep(5)"),
                                          export_timeout=0.3)
                check('navigation integration export timeout preserves nonzero', False, 'no SystemExit')
            except SystemExit as exit_error:
                check('navigation integration export timeout preserves nonzero',
                      exit_error.code == 3, f'code={exit_error.code}')
            for label, exception in (('timeout', runner.StepTimeout('synthetic')),
                                     ('cancel', runner.StepCancelled('synthetic'))):
                def failing_run(run_exception=exception):
                    raise run_exception
                try:
                    navigation.run_navigation(failing_run, result, phases,
                                              export_command=child("print('export-after-failure')"),
                                              export_timeout=5)
                    check(f'navigation integration preserves {label} exception', False, 'no exception')
                except (runner.StepTimeout, runner.StepCancelled) as propagated:
                    check(f'navigation integration preserves {label} exception',
                          type(propagated) is type(exception))
            code = navigation.run_navigation(lambda: 0, result, phases,
                                             export_command=[str(out / 'missing-export-fixture')],
                                             export_timeout=5)
            check('navigation integration export failure keeps success', code == 0, f'code={code}')

        if os.name == 'posix':
            ready = out / 'posix-descendant-ready'
            alive = out / 'posix-descendant-alive'
            grandchild = (
                "import pathlib, signal, sys, time\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                f"pathlib.Path({str(ready)!r}).write_text('ready')\n"
                "time.sleep(3)\n"
                f"pathlib.Path({str(alive)!r}).write_text('alive')\n"
                "time.sleep(30)\n"
            )
            parent = (
                "import pathlib, subprocess, sys, time\n"
                f"subprocess.Popen([sys.executable, '-c', {grandchild!r}])\n"
                "deadline = time.time() + 5\n"
                f"while not pathlib.Path({str(ready)!r}).exists():\n"
                "    if time.time() > deadline:\n"
                "        sys.exit(9)\n"
                "    time.sleep(0.02)\n"
                "sys.exit(0)\n"
            )
            started = time.monotonic()
            code = runner.run_streaming(child(parent), out / 'posix-descendant.log', phases,
                                        'posix-descendant-case', term_grace=1.0)
            elapsed = time.monotonic() - started
            check('posix descendant case leader exit preserved', code == 0, f'code={code}')
            check('posix descendant installed SIG_IGN before leader exit (ready handshake)',
                  ready.exists())
            time.sleep(3.5)
            check('ignoring-TERM descendant killed after leader exit (no alive marker)',
                  not alive.exists())
            check('owned-group SIGKILL escalation stayed bounded', elapsed < 6,
                  f'elapsed={elapsed:.2f}s')
        else:
            print('SKIP POSIX descendant readiness/escalation case (requires POSIX); '
                  'not counted as a pass', flush=True)

    failed = [name for name, ok in CHECKS if not ok]
    print(f'{len(CHECKS) - len(failed)}/{len(CHECKS)} local runner QA checks passed '
          '(local mocked QA, not simulator evidence)', flush=True)
    if failed:
        raise SystemExit(f'failed checks: {failed}')


if __name__ == '__main__':
    main()
