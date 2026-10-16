"""Local negative/success QA for preview_step_runner (not simulator evidence).

Run: python3 tool/check_preview_step_runner.py

Exercises the streaming step runner on this machine only: exact success,
preserved nonzero failure, bounded timeout cleanup and injected cancellation.
It never launches a simulator, XCTest or the preview app, and its output is
local mocked-QA evidence, not CI or device evidence.
"""
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

    failed = [name for name, ok in CHECKS if not ok]
    print(f'{len(CHECKS) - len(failed)}/{len(CHECKS)} local runner QA checks passed '
          '(local mocked QA, not simulator evidence)', flush=True)
    if failed:
        raise SystemExit(f'failed checks: {failed}')


if __name__ == '__main__':
    main()
