#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import dataclasses
import hashlib
import json
import math
import os
import statistics
import struct
import sys
import uuid
from pathlib import Path
from typing import Any

from dual_cache_harness.controller import (
    DualProcessTrialRunner,
    HarnessFailure,
    WorkerProcess,
    symmetric_arm_order,
)
from dual_cache_harness.schema import (
    ArtifactFileIdentity,
    ClosedWindowDescriptor,
    ExecutionIdentity,
    ModelExecutionIdentity,
)
from dual_cache_harness.real_preflight import run_model_preflight


ROOT = Path(__file__).resolve().parent
FAKE_COMMAND = (sys.executable, "-m", "dual_cache_harness.fake_worker")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def fake_identity() -> ExecutionIdentity:
    executable = Path(sys.executable).resolve()
    executable_stat = executable.stat()
    code_files = sorted((ROOT / "dual_cache_harness").glob("*.py"))
    code_digest = hashlib.sha256()
    for path in code_files:
        code_digest.update(path.name.encode())
        code_digest.update(path.read_bytes())
    fake_model = ArtifactFileIdentity(
        relative_path="FakeEncoder.mlmodelc/model.bin",
        byte_count=4,
        sha256=hashlib.sha256(b"fake").hexdigest(),
    )
    fake_vocabulary = ArtifactFileIdentity(
        relative_path="FakeVocabulary.mlmodelc/model.bin",
        byte_count=5,
        sha256=hashlib.sha256(b"vocab").hexdigest(),
    )
    return ExecutionIdentity.make(
        executable_sha256=sha256_file(executable),
        executable_device=executable_stat.st_dev,
        executable_inode=executable_stat.st_ino,
        code_revision=code_digest.hexdigest(),
        model_files=(fake_model,),
        vocabulary_files=(fake_vocabulary,),
        configuration={
            "dual_decode": False,
            "max_tokens_per_chunk": 600,
            "mel_chunk_context": False,
            "model_version": "v3",
            "parallel_chunk_concurrency": 4,
            "vocabulary_scheduling": "candidateRegions",
        },
        vocabulary={
            "bias_weight_bits": 0x4080_0000,
            "minimum_similarity_bits": 0x3F26_6666,
            "revision": 7,
            "terms": ["OpenRamble", "вайбкодинг"],
        },
        language_hint="ru",
        execution=ModelExecutionIdentity(
            ml_compute_units="all",
            encoder_placement="automatic",
            hardware_model="fake-mac",
            architecture="arm64",
            os_version="fake-26.0",
            os_build="FAKE26A1",
            coreml_bundle_version="999.0",
            coreml_bundle_build="FAKE",
            coreml_binary_identity_kind="synthetic_sha256",
            coreml_binary_sha256=hashlib.sha256(b"fake-coreml").hexdigest(),
        ),
    )


def fake_pcm() -> bytes:
    values = [((index % 17) - 8) / 16 for index in range(64)]
    return struct.pack(f"={len(values)}f", *values)


def fake_descriptor() -> ClosedWindowDescriptor:
    return ClosedWindowDescriptor(
        index=0,
        chunk_start=0,
        context_start=0,
        chunk_end=32,
        context_samples=0,
        chunk_start_offset=0,
        emit_tokens_after_frame=None,
        initial_time_index_override=None,
        stable_through_sample_count=32,
        earliest_safe_prefix_sample_count=33,
    )


def environment(identity: ExecutionIdentity) -> dict[str, str]:
    return {
        "DCHF_IDENTITY_JSON": json.dumps(
            identity.to_dict(), sort_keys=True, separators=(",", ":")
        ),
        "PYTHONPATH": str(ROOT),
    }


def percentile(values: list[float], percentile_value: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return math.nan
    rank = max(0, math.ceil(percentile_value * len(ordered)) - 1)
    return ordered[rank]


async def run_fake_matrix(offsets: list[int], n_per_arm: int) -> dict[str, Any]:
    identity = fake_identity()
    worker_environment = environment(identity)
    foreground = WorkerProcess(
        FAKE_COMMAND,
        role="foreground",
        expected_identity=identity,
        environment=worker_environment,
    )
    await foreground.launch()
    initial_resources = foreground.resource_snapshot()
    runner = DualProcessTrialRunner(
        foreground=foreground,
        speculative_command=FAKE_COMMAND,
        expected_identity=identity,
        speculative_environment=worker_environment,
    )
    pcm = fake_pcm()
    descriptor = fake_descriptor()
    observations = []
    reference = None
    killed_pids: list[int] = []
    try:
        for ordinal, (arm, offset) in enumerate(symmetric_arm_order(offsets, n_per_arm)):
            trial_id = f"matrix-{ordinal}-{uuid.uuid4()}"
            storage_id = str(uuid.uuid4())
            if arm == "baseline":
                observation = await runner.run_baseline(
                    pcm=pcm,
                    trial_id=trial_id,
                    capture_storage_id=storage_id,
                )
            else:
                observation = await runner.run_dual(
                    pcm=pcm,
                    trial_id=trial_id,
                    capture_storage_id=storage_id,
                    stop_offset_ms=offset,
                    speculation={
                        "active_ms": 250,
                        "completed_descriptors": [descriptor.to_dict()],
                        "planned_descriptors": [descriptor.to_dict()],
                    },
                )
                if observation.speculative_pid is not None:
                    killed_pids.append(observation.speculative_pid)
                if observation.adopted_cache_count != 1:
                    raise HarnessFailure("valid dual arm did not adopt its completed cache")
            if reference is None:
                reference = observation.result
            else:
                reference.assert_exact_parity(observation.result)
            observations.append(observation)
        final_resources = foreground.resource_snapshot()
    finally:
        await foreground.shutdown()

    for pid in killed_pids:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        raise HarnessFailure(f"orphan speculative PID {pid}")

    arms: dict[str, dict[str, Any]] = {}
    for arm in ("baseline", "dual"):
        durations = [
            item.stop_to_result_ns / 1_000_000 for item in observations if item.arm == arm
        ]
        arms[arm] = {
            "count": len(durations),
            "median_ms": statistics.median(durations),
            "p95_ms": percentile(durations, 0.95),
            "max_ms": max(durations),
        }
    fd_growth = final_resources.descriptor_count - initial_resources.descriptor_count
    if fd_growth > 2:
        raise HarnessFailure(f"foreground FD growth {fd_growth} exceeds 2")
    return {
        "backend": "fake",
        "identity_sha256": identity.canonical_sha256,
        "offsets_ms": offsets,
        "n_per_arm": n_per_arm,
        "full_exact_parity": True,
        "speculative_orphans": 0,
        "foreground_fd_growth": fd_growth,
        "foreground_phys_footprint_growth_bytes": (
            final_resources.resident_bytes - initial_resources.resident_bytes
        ),
        "max_live_children": 2,
        "arms": arms,
    }


FAULTS = (
    "cache_pcm_bitflip",
    "duplicate_index",
    "wrong_generation",
    "descriptor_mismatch",
    "identity_compute_units",
    "identity_os_build",
    "identity_coreml_build",
    "identity_coreml_binary",
    "identity_coreml_kind",
    "identity_model",
    "identity_config",
    "identity_language",
    "identity_vocabulary",
    "transport_digest",
    "exit_before_prediction",
    "stall_before_prediction",
    "malformed_frame",
)


async def run_fault_soak(cycles: int) -> dict[str, Any]:
    identity = fake_identity()
    worker_environment = environment(identity)
    foreground = WorkerProcess(
        FAKE_COMMAND,
        role="foreground",
        expected_identity=identity,
        environment=worker_environment,
    )
    await foreground.launch()
    runner = DualProcessTrialRunner(
        foreground=foreground,
        speculative_command=FAKE_COMMAND,
        expected_identity=identity,
        speculative_environment=worker_environment,
    )
    pcm = fake_pcm()
    descriptor = fake_descriptor()
    baseline = await runner.run_baseline(
        pcm=pcm,
        trial_id="fault-baseline",
        capture_storage_id=str(uuid.uuid4()),
    )
    initial_resources = foreground.resource_snapshot()
    killed_pids: list[int] = []
    counts: dict[str, int] = {}
    try:
        for index in range(cycles):
            fault = FAULTS[index % len(FAULTS)]
            counts[fault] = counts.get(fault, 0) + 1
            observation = await runner.run_dual(
                pcm=pcm,
                trial_id=f"fault-{index}",
                capture_storage_id=str(uuid.uuid4()),
                stop_offset_ms=0,
                speculation={
                    "active_ms": 250,
                    "completed_descriptors": [descriptor.to_dict()],
                    "planned_descriptors": [descriptor.to_dict()],
                    "fault": fault,
                },
                event_timeout=0.1,
            )
            baseline.result.assert_exact_parity(observation.result)
            if observation.adopted_cache_count != 0:
                raise HarnessFailure(f"fault {fault} cache was unexpectedly adopted")
            if observation.ordinary_final_invocations != 1:
                raise HarnessFailure(f"fault {fault} did not fall back exactly once")
            if observation.speculative_pid is not None:
                killed_pids.append(observation.speculative_pid)
        final_resources = foreground.resource_snapshot()
    finally:
        await foreground.shutdown()

    for pid in killed_pids:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        raise HarnessFailure(f"fault soak orphan PID {pid}")
    fd_growth = final_resources.descriptor_count - initial_resources.descriptor_count
    resident_growth = final_resources.resident_bytes - initial_resources.resident_bytes
    if fd_growth > 2:
        raise HarnessFailure(f"foreground FD growth {fd_growth} exceeds 2")
    return {
        "backend": "fake",
        "cycles": cycles,
        "fault_counts": counts,
        "ordinary_fallback_exactly_once": True,
        "full_exact_parity": True,
        "speculative_orphans": 0,
        "foreground_fd_growth": fd_growth,
        "foreground_phys_footprint_growth_bytes": resident_growth,
        "max_live_children": 2,
    }


def model_plan() -> dict[str, Any]:
    return {
        "status": "IMPLEMENTED_BUT_MODEL_EXECUTION_REQUIRES_SEPARATE_GO",
        "preflight": {
            "offsets_ms": [0, 25, 50, 75, 100],
            "n_per_arm": 2,
            "fixture_count": 1,
            "first_wave_reducing_eligibility_ms": 51_840,
            "expected_wall_minutes": "6-10",
            "command_after_separate_go": (
                "DCHF_COREML_GO_TOKEN=<root-reviewed-token> xcrun xctrace record "
                "--template 'Core ML' --instrument 'Points of Interest' "
                "--output <preflight.trace> --launch -- $(command -v python3) "
                "$TMP/openramble-dual-cache-model-preflight/harness/run.py "
                "model-preflight --allow-coreml-after-explicit-go "
                "--worker <release-same-artifact-worker> --spec <reviewed-spec.json> "
                "--fixture <frozen-real-f32le> --fixture-repeat <N> "
                "--offsets 0,25,50,75,100 --n-per-arm 2 --markers <markers.jsonl>"
            ),
            "required_measurements": {
                "idle_reuse": (
                    "two idle stop boundaries retain the same S PID/generation and avoid reload"
                ),
                "active_kill": (
                    "prediction-start marker -> exact SIGKILL/waitpid -> F kernel-exit "
                    "observation; F request starts only after reap"
                ),
                "replacement_prepare_containment": (
                    "causal PREPARE_STARTED ACK -> bounded pre-model hold -> exact "
                    "SIGKILL/waitpid -> F; does not claim native CoreML load/warm active"
                ),
                "cold_reload": (
                    "unadjusted kill-to-new-S model-ready/prewarm wall time, compared with "
                    "the next session's 51.84s wave-reducing eligibility"
                ),
            },
        },
        "full": {
            "offset_step_ms": 5,
            "offset_tail_ms": 100,
            "n_per_arm": 20,
            "fault_soak": 100,
            "expected_wall_hours": "3-4",
            "requires_preflight_pass": True,
        },
        "hard_gates": {
            "combined_phys_footprint_bytes": 12 * 1024**3,
            "host_memory_bytes": 16 * 1024**3,
            "fd_growth": 2,
            "max_child_processes": 2,
            "resource_sample_interval_ms": 10,
            "swap_growth_bytes": 0,
            "memory_pressure_pre_post": "normal",
            "coreml_trace_requires_no_global_ane_tail_after_kernel_observation": True,
            "active_kill_reap_deadline_ms": 250,
            "reject_if_global_ane_survives_kernel_observation": True,
            "require_exact_pid_bearing_compute_route_for_production": True,
            "current_exact_pid_route_proof": "BLOCKED_GLOBAL_ANE_SCHEMA_HAS_NO_PID",
            "cpu_or_gpu_speculation_fallback_allowed": False,
            "foreground_request_must_follow_waitpid": True,
            "full_result_parity": True,
        },
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    preflight = subparsers.add_parser("fake-preflight")
    preflight.add_argument("--n-per-arm", type=int, default=2)
    soak = subparsers.add_parser("fake-fault-soak")
    soak.add_argument("--cycles", type=int, default=100)
    subparsers.add_parser("print-model-plan")
    model = subparsers.add_parser("model-preflight")
    model.add_argument("--allow-coreml-after-explicit-go", action="store_true")
    model.add_argument("--worker", type=Path, required=True)
    model.add_argument("--spec", type=Path, required=True)
    model.add_argument("--fixture", type=Path, required=True)
    model.add_argument("--fixture-repeat", type=int, default=1)
    model.add_argument("--offsets", default="0,25,50,75,100")
    model.add_argument("--n-per-arm", type=int, default=2)
    model.add_argument(
        "--markers",
        type=Path,
        default=ROOT / "results" / "preflight-markers.jsonl",
    )
    model.add_argument(
        "--resources",
        type=Path,
        default=ROOT / "results" / "preflight-resources.jsonl",
    )
    model.add_argument(
        "--authorization-token-env", default="DCHF_COREML_GO_TOKEN"
    )
    subparsers.add_parser("model-full")
    return parser.parse_args()


async def async_main(arguments: argparse.Namespace) -> dict[str, Any]:
    if arguments.command == "fake-preflight":
        return await run_fake_matrix([0, 25, 50, 75, 100], arguments.n_per_arm)
    if arguments.command == "fake-fault-soak":
        return await run_fault_soak(arguments.cycles)
    if arguments.command == "print-model-plan":
        return model_plan()
    if arguments.command == "model-preflight":
        if not arguments.allow_coreml_after_explicit_go:
            raise HarnessFailure(
                "model execution is fail-closed without --allow-coreml-after-explicit-go"
            )
        token = os.environ.get(arguments.authorization_token_env)
        if not token:
            raise HarnessFailure(
                f"model execution is fail-closed without {arguments.authorization_token_env}"
            )
        offsets = [int(value) for value in arguments.offsets.split(",") if value]
        if offsets != sorted(set(offsets)) or any(value < 0 for value in offsets):
            raise HarnessFailure("offsets must be unique sorted nonnegative milliseconds")
        return await run_model_preflight(
            worker=arguments.worker,
            spec_path=arguments.spec,
            fixture=arguments.fixture,
            fixture_repeat=arguments.fixture_repeat,
            offsets=offsets,
            n_per_arm=arguments.n_per_arm,
            authorization_token=token,
            markers_path=arguments.markers,
            resource_series_path=arguments.resources,
        )
    raise HarnessFailure(
        "full model matrix is fail-closed until tiny preflight and trace acceptance pass"
    )


def main() -> int:
    arguments = parse_arguments()
    try:
        report = asyncio.run(async_main(arguments))
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}, sort_keys=True))
        return 1
    print(json.dumps({"ok": True, "report": report}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
