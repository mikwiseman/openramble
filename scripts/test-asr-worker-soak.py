#!/usr/bin/env python3
"""Run the deterministic ASR worker soak/fault acceptance lane.

Build output goes to stderr. Stdout and --result contain only the same
machine-readable JSON report, which never contains recognized text.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
APP_ROOT = ROOT / "apps" / "macos"
RUNTIME_ROOT = (
    Path.home()
    / "Library"
    / "Caches"
    / "is.waiwai.dictation.tests"
    / "asr-worker-soak"
)
REQUEST_PATH = RUNTIME_ROOT / "request.json"
STAGING_RESULT_PATH = RUNTIME_ROOT / "result.json"
LOCK_PATH = RUNTIME_ROOT / "runner.lock"


def failure_report(
    code: str,
    cycles: int,
    exit_code: int | None = None,
    thread_sanitizer_enabled: bool = False,
) -> dict[str, Any]:
    report: dict[str, Any] = {
        "schema_version": 1,
        "status": "fail",
        "failure_code": code,
        "cycles": cycles,
        "thread_sanitizer_enabled": thread_sanitizer_enabled,
        "transcript_text_recorded": False,
    }
    if exit_code is not None:
        report["xcodebuild_exit_code"] = exit_code
    return report


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def validate(
    report: dict[str, Any],
    requested_cycles: int,
    thread_sanitizer_enabled: bool,
) -> None:
    required_faults = {
        "disconnect-first-inference",
        "malformed-first-inference",
        "truncated-first-inference",
        "sigstop_timeout",
    }
    faults = report.get("faults")
    latency = report.get("latency_milliseconds")
    checks = [
        report.get("schema_version") == 1,
        report.get("status") == "pass",
        report.get("thread_sanitizer_enabled") is thread_sanitizer_enabled,
        isinstance(report.get("cycles"), int) and report["cycles"] >= requested_cycles,
        report.get("cancellation_tasks", 0) >= 128,
        report.get("cancellation_recovery_succeeded") is True,
        report.get("cancellation_recovery_elapsed_milliseconds", float("inf")) < 1_000,
        report.get("cancellation_parent_fd_growth", float("inf")) <= 2,
        report.get("descriptor_reuse_cycles", 0) >= 256,
        report.get("descriptor_parent_fd_growth", float("inf")) <= 2,
        report.get("orphan_count") == 0,
        report.get("child_launch_count") == report.get("child_reaped_count"),
        report.get("transcript_text_recorded") is False,
        isinstance(report.get("resource_samples"), list)
        and len(report["resource_samples"]) >= 11,
        isinstance(latency, dict)
        and latency.get("p99", float("inf")) < 25
        and latency.get("maximum", float("inf")) < 250,
        report.get("parent_fd_growth", float("inf")) <= 2,
        report.get("worker_fd_growth", float("inf")) <= 2,
        report.get("parent_rss_peak_growth_bytes", float("inf"))
        <= 16 * 1_024 * 1_024,
        report.get("worker_rss_peak_growth_bytes", float("inf"))
        <= 4 * 1_024 * 1_024,
        isinstance(faults, list)
        and {item.get("fault") for item in faults} == required_faults
        and all(item.get("recovery_succeeded") is True for item in faults),
    ]
    if not all(checks):
        raise ValueError("acceptance report did not satisfy its schema or gates")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cycles", type=int, default=1_000)
    parser.add_argument(
        "--result",
        type=Path,
        default=Path(tempfile.gettempdir())
        / f"openramble-asr-worker-soak-{os.getpid()}.json",
    )
    parser.add_argument("--derived-data", type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=300)
    parser.add_argument("--thread-sanitizer", action="store_true")
    parser.add_argument("--skip-generate", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.cycles < 1_000:
        report = failure_report(
            "cycles_below_acceptance_minimum",
            arguments.cycles,
            thread_sanitizer_enabled=arguments.thread_sanitizer,
        )
        write_report(arguments.result, report)
        print(json.dumps(report, sort_keys=True))
        return 2
    if arguments.timeout_seconds < 30:
        report = failure_report(
            "timeout_below_safe_minimum",
            arguments.cycles,
            thread_sanitizer_enabled=arguments.thread_sanitizer,
        )
        write_report(arguments.result, report)
        print(json.dumps(report, sort_keys=True))
        return 2

    if not arguments.skip_generate:
        try:
            generator = subprocess.check_output(
                [str(ROOT / "scripts" / "pinned-xcodegen.sh")],
                cwd=ROOT,
                text=True,
                timeout=60,
            ).strip()
            subprocess.run(
                [generator, "generate"],
                cwd=APP_ROOT,
                check=True,
                stdout=sys.stderr,
                stderr=sys.stderr,
                timeout=30,
            )
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            report = failure_report(
                "xcodegen_failed",
                arguments.cycles,
                getattr(error, "returncode", None),
                arguments.thread_sanitizer,
            )
            write_report(arguments.result, report)
            print(json.dumps(report, sort_keys=True))
            return 1

    RUNTIME_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    RUNTIME_ROOT.chmod(0o700)
    with LOCK_PATH.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        arguments.result.unlink(missing_ok=True)
        STAGING_RESULT_PATH.unlink(missing_ok=True)
        write_report(
            REQUEST_PATH,
            {
                "cycles": arguments.cycles,
                "thread_sanitizer_enabled": arguments.thread_sanitizer,
            },
        )
        environment = os.environ.copy()
        environment["OPENRAMBLE_ASR_SOAK_CYCLES"] = str(arguments.cycles)
        command = [
            "xcodebuild",
            "-quiet",
            "-project",
            "OpenRamble.xcodeproj",
            "-scheme",
            "OpenRamble",
            "-destination",
            "platform=macOS,arch=arm64",
            "-parallel-testing-enabled",
            "NO",
            "-maximum-parallel-testing-workers",
            "1",
            "-test-timeouts-enabled",
            "YES",
            "-default-test-execution-time-allowance",
            "60",
            "-maximum-test-execution-time-allowance",
            "120",
            "CODE_SIGNING_ALLOWED=NO",
            "-only-testing:OpenRambleTests/ASRWorkerSoakTests",
        ]
        if arguments.derived_data is not None:
            command.extend(["-derivedDataPath", str(arguments.derived_data.resolve())])
        if arguments.thread_sanitizer:
            command.extend(["-enableThreadSanitizer", "YES"])
        command.append("test")
        timed_out = False
        launch_failed = False
        try:
            try:
                process = subprocess.Popen(
                    command,
                    cwd=APP_ROOT,
                    env=environment,
                    stdout=sys.stderr,
                    stderr=sys.stderr,
                    start_new_session=True,
                )
            except OSError:
                launch_failed = True
                completed_return_code = 127
            else:
                try:
                    completed_return_code = process.wait(timeout=arguments.timeout_seconds)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    completed_return_code = process.wait()
        finally:
            REQUEST_PATH.unlink(missing_ok=True)

        if STAGING_RESULT_PATH.exists():
            try:
                report = json.loads(STAGING_RESULT_PATH.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                report = failure_report(
                    "artifact_invalid",
                    arguments.cycles,
                    completed_return_code,
                    arguments.thread_sanitizer,
                )
        else:
            report = failure_report(
                "acceptance_timeout"
                if timed_out
                else (
                    "xcodebuild_launch_failed"
                    if launch_failed
                    else ("xcodebuild_failed" if completed_return_code else "artifact_missing")
                ),
                arguments.cycles,
                124 if timed_out else completed_return_code,
                arguments.thread_sanitizer,
            )
        build_failed = timed_out or launch_failed or completed_return_code != 0
        if build_failed and report.get("status") == "pass":
            report = failure_report(
                "acceptance_timeout"
                if timed_out
                else ("xcodebuild_launch_failed" if launch_failed else "xcodebuild_failed"),
                arguments.cycles,
                124 if timed_out else completed_return_code,
                arguments.thread_sanitizer,
            )
        write_report(arguments.result, report)
        if arguments.result.resolve() != STAGING_RESULT_PATH.resolve():
            STAGING_RESULT_PATH.unlink(missing_ok=True)

        if timed_out or launch_failed or completed_return_code != 0:
            print(json.dumps(report, sort_keys=True))
            return 124 if timed_out else completed_return_code

        try:
            validate(report, arguments.cycles, arguments.thread_sanitizer)
        except (ValueError, TypeError, KeyError):
            report = failure_report(
                "artifact_validation_failed",
                arguments.cycles,
                thread_sanitizer_enabled=arguments.thread_sanitizer,
            )
            write_report(arguments.result, report)
            print(json.dumps(report, sort_keys=True))
            return 1

        print(json.dumps(report, sort_keys=True))
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
