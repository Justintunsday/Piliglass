"""Streaming, non-masking subprocess lifecycle for the iOS preview steps.

preview_ios_navigation.py previously ran xcodebuild with an unbounded
subprocess.run(stdout=log): the last-16000-chars print and the xcresult
attachment export happened only after a normal child return, so a stalled child
could consume the whole job budget while live phase/test output never reached
the job log and no artifacts were exported for the always-upload steps.

This module tees child output incrementally to a local log and to stdout,
writes timestamped phase markers to a second file, preserves nonzero failures
exactly, and stops a child process group with a bounded SIGTERM -> grace ->
SIGKILL sequence when the step is cancelled or times out. It performs no
simulator or XCTest work and never converts a failure into success.
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


def terminate_process_group(process, grace=DEFAULT_TERM_GRACE_SECONDS):
    """Bounded stop of a start_new_session child; returns a status string."""
    if process.poll() is not None:
        return 'exited'
    if hasattr(os, 'killpg'):
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            return 'exited'
    else:  # pragma: no cover - local fallback outside POSIX
        process.terminate()
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        if process.poll() is not None:
            return 'terminated'
        time.sleep(0.05)
    if hasattr(os, 'killpg') and hasattr(signal, 'SIGKILL'):
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    else:  # pragma: no cover - local fallback outside POSIX
        process.kill()
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        return 'kill-pending'
    return 'killed'


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
    failure (never masked). ``timeout`` is optional and unused by the
    navigation step, whose only bound stays the workflow job budget. A
    cancelled step is stopped with the same bounded cleanup and re-raised as
    ``StepCancelled`` so CI still fails.
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
                try:
                    line = lines.get(timeout=_READ_POLL_SECONDS)
                except queue.Empty:
                    if cancel_event.is_set():
                        stop_reason = 'cancelled'
                        break
                    if deadline is not None and time.monotonic() >= deadline:
                        stop_reason = 'timeout'
                        break
                    continue
                if line is None:
                    break
                log.write(line)
                log.flush()
                tail.append(line)
                tail_total += len(line)
                while len(tail) > 1 and tail_total > tail_chars:
                    tail_total -= len(tail.popleft())
                sys.stdout.write(line)
                sys.stdout.flush()
            if stop_reason is not None:
                outcome = terminate_process_group(process, term_grace)
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
            if process.poll() is None:
                terminate_process_group(process, term_grace)
