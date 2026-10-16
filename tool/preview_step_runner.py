"""Streaming, non-masking subprocess lifecycle for the iOS preview steps.

preview_ios_navigation.py previously ran xcodebuild with an unbounded
subprocess.run(stdout=log): the last-16000-chars print and the xcresult
attachment export happened only after a normal child return, so a stalled child
could consume the whole job budget while live phase/test output never reached
the job log and no artifacts were exported for the always-upload steps.

This module tees child output incrementally to a local log and to stdout,
writes timestamped phase markers to a second file, preserves nonzero failures
exactly, and stops the owned process group with a bounded SIGTERM -> grace ->
SIGKILL sequence when the step is cancelled or times out. Cancellation and
deadline checks run on every loop iteration, independent of output
availability; stdout EOF is a stream state, never child completion, so a
live child keeps being polled (and can still be cancelled/timed out) until it
actually exits. It performs no simulator or XCTest work and never converts a
failure into success.
"""
from __future__ import annotations

import collections
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

DEFAULT_TERM_GRACE_SECONDS = 10.0
_READ_POLL_SECONDS = 0.2


class StepTimeout(RuntimeError):
    """The step exceeded its explicitly requested deadline."""


class StepCancelled(RuntimeError):
    """The step received SIGTERM/SIGINT or an injected cancel request."""


def utc_timestamp():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


class PhaseLog:
    """Append-only timestamped phase markers, flushed and fsynced per line."""

    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def mark(self, message):
        line = f'{utc_timestamp()} {message}\n'
        with self.path.open('a', encoding='utf-8') as handle:
            handle.write(line)
            handle.flush()
            os.fsync(handle.fileno())
        print(f'[phase] {line}'.rstrip(), flush=True)


def _capture_process_group(process):
    """Owned PGID captured while the leader is alive, or None off POSIX."""
    getpgid = getattr(os, 'getpgid', None)
    if getpgid is None:
        return None
    try:
        return getpgid(process.pid)
    except (ProcessLookupError, PermissionError, OSError):
        return None


def _group_alive(pgid):
    if pgid is None or not hasattr(os, 'killpg'):
        return False
    try:
        os.killpg(pgid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False
    except OSError:
        return False


def _signal_process_group(process, pgid, signal_value):
    """Signal only the owned group (or the direct child outside POSIX)."""
    if pgid is not None and hasattr(os, 'killpg'):
        try:
            os.killpg(pgid, signal_value)
            return True
        except (ProcessLookupError, PermissionError):
            return False
        except OSError:
            return False
    try:
        if signal_value == getattr(signal, 'SIGTERM', None):
            process.terminate()
        else:
            process.kill()
        return True
    except OSError:
        return False


def terminate_process_group(process, pgid=None, grace=DEFAULT_TERM_GRACE_SECONDS):
    """Bounded SIGTERM -> grace -> SIGKILL stop of the owned process group.

    The group id is captured while the child is alive, so cleanup still reaches
    descendants that ignore SIGTERM after the leader itself has exited. Only the
    owned group is signalled: never an unrelated pid or group."""
    if pgid is None:
        pgid = _capture_process_group(process)
    if process.poll() is None or _group_alive(pgid):
        _signal_process_group(process, pgid, signal.SIGTERM)
    else:
        return 'exited'
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        if process.poll() is not None and not _group_alive(pgid):
            return 'terminated'
        time.sleep(0.05)
    kill_signal = getattr(signal, 'SIGKILL', signal.SIGTERM)
    _signal_process_group(process, pgid, kill_signal)
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        if process.poll() is not None and not _group_alive(pgid):
            return 'killed'
        time.sleep(0.05)
    return 'kill-pending'


def run_bounded_cleanup(command, phases, name, timeout=600):
    """Best-effort bounded cleanup command; never raises and never masks the
    primary step outcome. Diagnostics cannot guarantee uploads after an outer
    hard cancel, so this is recorded as local evidence only."""
    try:
        completed = subprocess.run(command, check=False, timeout=timeout)
    except subprocess.TimeoutExpired:
        phases.mark(f'{name}: timed out (bounded {timeout}s)')
        return None
    except Exception as error:  # a missing binary must not mask the step
        phases.mark(f'{name}: failed ({error.__class__.__name__})')
        return None
    phases.mark(f'{name}: exit {completed.returncode}')
    return completed.returncode


def _drain(lines, log, tail):
    while True:
        try:
            line = lines.get_nowait()
        except queue.Empty:
            break
        if line is None:
            continue
        log.write(line)
        tail.append(line)
        sys.stdout.write(line)
    log.flush()
    sys.stdout.flush()


def run_streaming(command, log_path, phases, name, *,
                  timeout=None, cancel_event=None,
                  term_grace=DEFAULT_TERM_GRACE_SECONDS, tail_chars=16000):
    """Run one step while streaming output to the log and to stdout.

    Returns the child's exact exit code; a nonzero code is preserved as a
    failure (never masked). Cancellation and deadline checks run on every
    iteration, independent of output availability, and stdout EOF does not
    count as completion: the loop keeps bounded polling until the child really
    exits, so a cancel/timeout racing with EOF or exit cannot report success.
    ``timeout`` is optional and unused by the navigation step, whose only bound
    stays the workflow job budget. A cancelled step is stopped with the same
    bounded cleanup and re-raised as ``StepCancelled`` so CI still fails.
    """
    log_path = Path(log_path)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    if cancel_event is None:
        cancel_event = threading.Event()
        owned_cancel = True
    else:
        owned_cancel = False
    phases.mark(f'{name}: launch {command[0]}')
    deadline = None if timeout is None else time.monotonic() + timeout
    tail = collections.deque()
    tail_total = 0

    with log_path.open('w', encoding='utf-8', errors='replace') as log:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors='replace',
            bufsize=1,
            start_new_session=(os.name == 'posix'),
        )
        pgid = _capture_process_group(process)
        lines = queue.Queue()

        def pump():
            try:
                for line in process.stdout:
                    lines.put(line)
            finally:
                lines.put(None)

        reader = threading.Thread(target=pump, name=f'{name}-reader', daemon=True)
        reader.start()

        previous_handlers = {}
        if owned_cancel:
            def _request_cancel(signum, frame):
                cancel_event.set()

            for signal_name in ('SIGTERM', 'SIGINT'):
                signal_value = getattr(signal, signal_name, None)
                if signal_value is None:
                    continue
                try:
                    previous_handlers[signal_value] = signal.signal(signal_value, _request_cancel)
                except ValueError:
                    pass

        stop_reason = None
        try:
            while True:
                # Checks run on every iteration, independent of output
                # availability, so busy/backlogged output cannot suppress a
                # cancellation or an expired deadline.
                if cancel_event.is_set():
                    stop_reason = 'cancelled'
                    break
                if deadline is not None and time.monotonic() >= deadline:
                    stop_reason = 'timeout'
                    break
                try:
                    line = lines.get(timeout=_READ_POLL_SECONDS)
                except queue.Empty:
                    if process.poll() is not None:
                        break
                    continue
                if line is None:
                    # stdout EOF is a stream state, not child completion: keep
                    # bounded polling (checks above) until the child exits.
                    continue
                log.write(line)
                log.flush()
                tail.append(line)
                tail_total += len(line)
                while len(tail) > 1 and tail_total > tail_chars:
                    tail_total -= len(tail.popleft())
                sys.stdout.write(line)
                sys.stdout.flush()
            if stop_reason is not None:
                outcome = terminate_process_group(process, pgid, term_grace)
                _drain(lines, log, tail)
                phases.mark(f'{name}: {stop_reason}; child {outcome}')
                if stop_reason == 'timeout':
                    raise StepTimeout(f'{name} exceeded its {timeout}s deadline')
                raise StepCancelled(f'{name} was cancelled')
            code = process.wait()
            _drain(lines, log, tail)
            phases.mark(f'{name}: exit {code}')
            if code:
                excerpt = ''.join(tail)[-tail_chars:]
                print(f'[{name}] last {len(excerpt)} chars of streamed output:\n{excerpt}', flush=True)
            return code
        finally:
            for signal_value, handler in previous_handlers.items():
                signal.signal(signal_value, handler)
            # Bounded cleanup on every exit path: even a normally-finished
            # leader can leave ignoring-SIGTERM descendants in the owned group.
            terminate_process_group(process, pgid, term_grace)
