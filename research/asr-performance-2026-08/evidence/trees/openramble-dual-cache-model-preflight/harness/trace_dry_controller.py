#!/usr/bin/env python3
"""CPU-only xctrace fixture for process-exit/signpost export validation."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import time
from pathlib import Path


TRIAL_TAG = 0x4452595452414345  # ASCII "DRYTRACE"


def _ready(process: subprocess.Popen[str], expected_role: str) -> dict[str, object]:
    assert process.stdout is not None
    line = process.stdout.readline()
    if not line:
        stderr = process.stderr.read() if process.stderr else ""
        raise RuntimeError(f"{expected_role} did not become ready: {stderr}")
    value = json.loads(line)
    if value.get("role") != expected_role or int(value.get("trial_tag", -1)) != TRIAL_TAG:
        raise RuntimeError(f"unexpected {expected_role} ready record: {value}")
    if int(value.get("pid", -1)) != process.pid:
        raise RuntimeError(f"{expected_role} ready PID does not match exact child")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--markers", type=Path, required=True)
    arguments = parser.parse_args()
    worker = arguments.worker.resolve(strict=True)
    arguments.markers.parent.mkdir(parents=True, exist_ok=True)

    speculative = subprocess.Popen(
        [str(worker), "--trace-dry-speculative", str(TRIAL_TAG), "60000"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    _ready(speculative, "speculative")
    observer = subprocess.Popen(
        [
            str(worker),
            "--trace-dry-observer",
            str(speculative.pid),
            str(TRIAL_TAG),
            "5000",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        _ready(observer, "foreground-observer")
        killed_ns = time.monotonic_ns()
        speculative.kill()
        speculative_return_code = speculative.wait(timeout=1)
        reaped_ns = time.monotonic_ns()
        observer_return_code = observer.wait(timeout=5)
        if speculative_return_code != -signal.SIGKILL:
            raise RuntimeError(f"S return code was {speculative_return_code}, expected -9")
        if observer_return_code != 0:
            stderr = observer.stderr.read() if observer.stderr else ""
            raise RuntimeError(f"exit observer failed ({observer_return_code}): {stderr}")
        marker = {
            "event": "trace_dry_sigkill_waitpid",
            "trial_id": "trace-dry",
            "trial_tag": TRIAL_TAG,
            "speculative_pid": speculative.pid,
            "observer_pid": observer.pid,
            "sigkill_monotonic_ns": killed_ns,
            "waitpid_monotonic_ns": reaped_ns,
            "reap_duration_ns": reaped_ns - killed_ns,
            "process_return_code": speculative_return_code,
        }
        arguments.markers.write_text(
            json.dumps(marker, sort_keys=True, separators=(",", ":")) + "\n"
        )
        return 0
    finally:
        for process in (speculative, observer):
            if process.poll() is None:
                process.kill()
                process.wait(timeout=1)


if __name__ == "__main__":
    raise SystemExit(main())
