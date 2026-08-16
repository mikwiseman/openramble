from __future__ import annotations

import asyncio
import ctypes
import dataclasses
import hashlib
import json
import os
import platform
import plistlib
import re
import statistics
import struct
import subprocess
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

from .controller import (
    BoundedResourceSampler,
    HarnessFailure,
    PrepareInterruptionObservation,
    TrialObservation,
    WorkerProcess,
    exact_trial_tag,
    symmetric_arm_order,
)
from .schema import (
    ArtifactFileIdentity,
    AuditedResult,
    ExecutionIdentity,
    MAX_FINAL_SAMPLES,
    ModelExecutionIdentity,
    SerializedClosedWindowCache,
    canonical_json_bytes,
)
from .wire import Kind


FIRST_WAVE_REDUCING_SAMPLES = 829_440  # 51.84 s at 16 kHz
REAP_DEADLINE_NS = 250_000_000
COMBINED_FOOTPRINT_LIMIT = 12 * 1024**3
NORMAL_MEMORY_PRESSURE_LEVEL = 1


def trial_tag(trial_id: str) -> int:
    return exact_trial_tag(trial_id)


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def _artifact_files(root: Path) -> tuple[ArtifactFileIdentity, ...]:
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise HarnessFailure(f"artifact root is not a directory: {root}")
    result: list[ArtifactFileIdentity] = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise HarnessFailure(f"artifact symlink is forbidden: {path}")
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        result.append(
            ArtifactFileIdentity(
                relative_path=relative,
                byte_count=path.stat().st_size,
                sha256=_sha256_file(path),
            )
        )
        if len(result) > 100_000:
            raise HarnessFailure("artifact file count exceeds 100000")
    return tuple(result)


def _sysctl(name: str) -> str:
    value = subprocess.check_output(
        ["/usr/sbin/sysctl", "-n", name], text=True
    ).strip()
    if not value:
        raise HarnessFailure(f"empty sysctl {name}")
    return value


@dataclass(frozen=True)
class SystemMemorySnapshot:
    captured_monotonic_ns: int
    swapusage_raw: str
    swap_total_bytes: int
    swap_available_bytes: int
    swap_used_bytes: int
    swap_page_size_bytes: int
    swap_encrypted: bool
    memory_pressure_query_raw: str
    memory_free_percent: int
    pressure_level_raw: str
    pressure_level: int


@dataclass(frozen=True)
class ExactSwapUsage:
    total_bytes: int
    available_bytes: int
    used_bytes: int
    page_size_bytes: int
    encrypted: bool


_XSW_USAGE = struct.Struct("<QQQIB3s")
_XSW_USAGE_SIZE = 32
_MEMORY_FREE = re.compile(r"System-wide memory free percentage:\s*([0-9]+)%")


def parse_exact_swapusage(raw: bytes) -> ExactSwapUsage:
    if len(raw) != _XSW_USAGE_SIZE:
        raise HarnessFailure(
            f"vm.swapusage ABI size mismatch: expected {_XSW_USAGE_SIZE}, got {len(raw)}"
        )
    total, available, used, page_size, encrypted, padding = _XSW_USAGE.unpack(raw)
    if padding != b"\0\0\0":
        raise HarnessFailure("vm.swapusage encrypted-field padding is nonzero")
    if encrypted not in (0, 1):
        raise HarnessFailure("vm.swapusage encrypted field is not boolean")
    if page_size == 0 or page_size & (page_size - 1):
        raise HarnessFailure("vm.swapusage page size is not a positive power of two")
    if used > total:
        raise HarnessFailure("vm.swapusage used bytes exceed total bytes")
    if total != available + used:
        raise HarnessFailure("vm.swapusage total does not equal available plus used")
    return ExactSwapUsage(
        total_bytes=total,
        available_bytes=available,
        used_bytes=used,
        page_size_bytes=page_size,
        encrypted=bool(encrypted),
    )


def _sysctlbyname_bytes(name: str) -> bytes:
    libc = ctypes.CDLL(None, use_errno=True)
    sysctlbyname = libc.sysctlbyname
    sysctlbyname.argtypes = (
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.c_void_p,
        ctypes.c_size_t,
    )
    sysctlbyname.restype = ctypes.c_int
    encoded = name.encode("ascii")
    size = ctypes.c_size_t()
    if sysctlbyname(encoded, None, ctypes.byref(size), None, 0) != 0:
        error_number = ctypes.get_errno()
        raise HarnessFailure(
            f"sysctlbyname({name!r}) size query failed with errno {error_number}"
        )
    if size.value != _XSW_USAGE_SIZE:
        raise HarnessFailure(
            f"vm.swapusage ABI size mismatch: expected {_XSW_USAGE_SIZE}, got {size.value}"
        )
    buffer = ctypes.create_string_buffer(size.value)
    returned_size = ctypes.c_size_t(size.value)
    if sysctlbyname(encoded, buffer, ctypes.byref(returned_size), None, 0) != 0:
        error_number = ctypes.get_errno()
        raise HarnessFailure(
            f"sysctlbyname({name!r}) read failed with errno {error_number}"
        )
    if returned_size.value != size.value:
        raise HarnessFailure(
            f"vm.swapusage ABI size changed during read: {size.value}->{returned_size.value}"
        )
    return bytes(buffer.raw[: returned_size.value])


def parse_memory_pressure_free_percent(raw: str) -> int:
    matches = _MEMORY_FREE.findall(raw)
    if len(matches) != 1:
        raise HarnessFailure("memory_pressure -Q output lacks one free percentage")
    value = int(matches[0])
    if not 0 <= value <= 100:
        raise HarnessFailure("memory_pressure -Q percentage is out of range")
    return value


def parse_memory_pressure_level(raw: str) -> int:
    stripped = raw.strip()
    if not re.fullmatch(r"[0-9]+", stripped):
        raise HarnessFailure("kernel memory-pressure level is not an integer")
    return int(stripped)


def _command_text(arguments: Sequence[str]) -> str:
    result = subprocess.run(arguments, text=True, capture_output=True)
    if result.returncode != 0:
        raise HarnessFailure(
            f"resource command {arguments!r} failed: "
            f"{(result.stderr or result.stdout).strip()}"
        )
    if not result.stdout.strip():
        raise HarnessFailure(f"resource command {arguments!r} returned no output")
    return result.stdout.strip()


def capture_system_memory_snapshot() -> SystemMemorySnapshot:
    exact_swap = parse_exact_swapusage(_sysctlbyname_bytes("vm.swapusage"))
    swap_raw = _command_text(("/usr/sbin/sysctl", "-n", "vm.swapusage"))
    pressure_query_raw = _command_text(("/usr/bin/memory_pressure", "-Q"))
    pressure_level_raw = _command_text(
        ("/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level")
    )
    return SystemMemorySnapshot(
        captured_monotonic_ns=time.monotonic_ns(),
        swapusage_raw=swap_raw,
        swap_total_bytes=exact_swap.total_bytes,
        swap_available_bytes=exact_swap.available_bytes,
        swap_used_bytes=exact_swap.used_bytes,
        swap_page_size_bytes=exact_swap.page_size_bytes,
        swap_encrypted=exact_swap.encrypted,
        memory_pressure_query_raw=pressure_query_raw,
        memory_free_percent=parse_memory_pressure_free_percent(pressure_query_raw),
        pressure_level_raw=pressure_level_raw,
        pressure_level=parse_memory_pressure_level(pressure_level_raw),
    )


def validate_system_memory_gate(
    pre: SystemMemorySnapshot, post: SystemMemorySnapshot | None = None
) -> None:
    if pre.pressure_level != NORMAL_MEMORY_PRESSURE_LEVEL:
        raise HarnessFailure(
            f"preflight memory pressure is not normal: level={pre.pressure_level}"
        )
    if post is None:
        return
    if post.pressure_level != NORMAL_MEMORY_PRESSURE_LEVEL:
        raise HarnessFailure(
            f"postflight memory pressure is not normal: level={post.pressure_level}"
        )
    if post.swap_used_bytes > pre.swap_used_bytes:
        raise HarnessFailure(
            "swap grew during preflight: "
            f"{pre.swap_used_bytes}->{post.swap_used_bytes} bytes"
        )


def write_system_memory_report(
    path: Path,
    *,
    pre: SystemMemorySnapshot | None,
    post: SystemMemorySnapshot | None,
    error: str | None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "normal_pressure_level": NORMAL_MEMORY_PRESSURE_LEVEL,
                "pre": dataclasses.asdict(pre) if pre is not None else None,
                "post": dataclasses.asdict(post) if post is not None else None,
                "swap_delta_bytes": (
                    post.swap_used_bytes - pre.swap_used_bytes
                    if pre is not None and post is not None
                    else None
                ),
                "error": error,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )


def _os_version() -> str:
    version = platform.mac_ver()[0]
    parts = version.split(".")
    while len(parts) < 3:
        parts.append("0")
    return ".".join(parts[:3])


def _coreml_metadata() -> tuple[str, str, str, str]:
    bundle = Path("/System/Library/Frameworks/CoreML.framework")
    info_candidates = (
        bundle / "Resources" / "Info.plist",
        bundle / "Versions" / "A" / "Resources" / "Info.plist",
        bundle / "Versions" / "Current" / "Resources" / "Info.plist",
    )
    info_path = next((candidate for candidate in info_candidates if candidate.exists()), None)
    if info_path is None:
        raise HarnessFailure("CoreML Info.plist not found")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    executable_name = str(info.get("CFBundleExecutable", "CoreML"))
    executable_candidates = (
        bundle / executable_name,
        bundle / "Versions" / "A" / executable_name,
        bundle / "Versions" / "Current" / executable_name,
    )
    version = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    if not version or not build:
        raise HarnessFailure("CoreML bundle version/build missing")
    executable = next(
        (candidate for candidate in executable_candidates if candidate.exists()), None
    )
    if executable is not None:
        return version, build, "file_sha256", _sha256_file(executable)

    output = subprocess.check_output(
        [
            "/usr/bin/xcrun",
            "dyld_info",
            "-uuid",
            str(bundle / executable_name),
        ],
        text=True,
    )
    match = re.search(
        r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        output,
    )
    if match is None:
        raise HarnessFailure("CoreML Mach-O UUID not found in dyld shared cache")
    record = {
        "info_plist_sha256": _sha256_file(info_path),
        "macho_uuid": match.group(0).upper(),
    }
    return (
        version,
        build,
        "dyld_macho_uuid_info_plist_sha256",
        hashlib.sha256(canonical_json_bytes(record)).hexdigest(),
    )


def load_real_identity(
    *, worker: Path, spec_path: Path
) -> tuple[ExecutionIdentity, dict[str, Any]]:
    worker = worker.resolve(strict=True)
    spec_path = spec_path.resolve(strict=True)
    spec = json.loads(spec_path.read_text())
    if int(spec.get("schema_version", -1)) != 1:
        raise HarnessFailure("unsupported real-worker spec version")
    configuration = spec["configuration"]
    if not (
        configuration.get("model_version") == "v3"
        and configuration.get("mel_chunk_context") is False
        and configuration.get("dual_decode_arbitration") is False
        and configuration.get("parallel_chunk_concurrency") == 4
        and configuration.get("vocabulary_scheduling") == "candidateRegions"
        and configuration.get("encoder_placement") == "automatic"
        and configuration.get("ml_compute_units") == "all"
    ):
        raise HarnessFailure("real-worker spec is outside exact shipping cache gate")
    authorization_digest = str(spec.get("authorization_token_sha256", ""))
    if len(authorization_digest) != 64 or any(
        char not in "0123456789abcdef" for char in authorization_digest
    ):
        raise HarnessFailure("invalid authorization-token digest")
    coreml_version, coreml_build, coreml_kind, coreml_sha = _coreml_metadata()
    stat = worker.stat()
    vocabulary_directory = spec.get("vocabulary_model_directory")
    identity = ExecutionIdentity.make(
        executable_sha256=_sha256_file(worker),
        executable_device=stat.st_dev,
        executable_inode=stat.st_ino,
        code_revision=str(spec["code_revision"]),
        model_files=_artifact_files(Path(spec["model_directory"])),
        vocabulary_files=(
            _artifact_files(Path(vocabulary_directory)) if vocabulary_directory else ()
        ),
        configuration=configuration,
        vocabulary=spec["vocabulary"],
        language_hint=spec.get("language_hint"),
        execution=ModelExecutionIdentity(
            ml_compute_units=str(configuration["ml_compute_units"]),
            encoder_placement=str(configuration["encoder_placement"]),
            hardware_model=_sysctl("hw.model"),
            architecture=platform.machine(),
            os_version=_os_version(),
            os_build=_sysctl("kern.osversion"),
            coreml_bundle_version=coreml_version,
            coreml_bundle_build=coreml_build,
            coreml_binary_identity_kind=coreml_kind,
            coreml_binary_sha256=coreml_sha,
        ),
    )
    return identity, spec


class MarkerRecorder:
    def __init__(self, path: Path) -> None:
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        self._stream = path.open("w", encoding="utf-8")

    def record(self, event: str, **fields: Any) -> None:
        value = {"event": event, "controller_monotonic_ns": time.monotonic_ns(), **fields}
        self._stream.write(
            json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            + "\n"
        )
        self._stream.flush()

    def close(self) -> None:
        self._stream.close()


@dataclass(frozen=True)
class RealTrialResult:
    observation: TrialObservation
    reload_wall_ns: int | None
    peak_combined_footprint_bytes: int
    active_kill: bool


class RealPreflightRunner:
    def __init__(
        self,
        *,
        foreground: WorkerProcess,
        worker_command: Sequence[str],
        expected_identity: ExecutionIdentity,
        environment: Mapping[str, str],
        markers: MarkerRecorder,
        resources: BoundedResourceSampler,
    ) -> None:
        self.foreground = foreground
        self.worker_command = tuple(worker_command)
        self.expected_identity = expected_identity
        self.environment = dict(environment)
        self.markers = markers
        self.resources = resources
        self.reaped_pids: list[int] = []
        self.live_speculative: list[tuple[str, WorkerProcess]] = []

    def _register_speculative(self, resource_role: str, worker: WorkerProcess) -> None:
        self.live_speculative.append((resource_role, worker))
        self.resources.track(resource_role, worker)

    def _forget_speculative(self, resource_role: str, worker: WorkerProcess) -> None:
        self.resources.retire_if_tracked(resource_role, worker)
        try:
            self.live_speculative.remove((resource_role, worker))
        except ValueError:
            pass

    async def cleanup_speculative(self) -> None:
        pending = list(self.live_speculative)
        self.live_speculative.clear()
        for resource_role, worker in pending:
            self.resources.retire_if_tracked(resource_role, worker)
            if worker.process is not None:
                pid = worker.pid
                await worker.kill_and_reap(allow_already_exited=True)
                self.reaped_pids.append(pid)

    async def baseline(
        self, *, pcm: bytes, trial_id: str, storage_id: str, offset_ms: int
    ) -> RealTrialResult:
        started = time.monotonic_ns()
        self.resources.checkpoint("baseline_foreground_start")
        self.markers.record(
            "foreground_request",
            arm="baseline",
            trial_id=trial_id,
            pid=self.foreground.pid,
            trial_tag=trial_tag(trial_id),
            request_monotonic_ns=started,
        )
        response = await self.foreground.request(
            Kind.TRANSCRIBE,
            {
                "trial_id": trial_id,
                "capture_storage_id": storage_id,
                "speculative_generation": None,
                "cache_count": 0,
            },
            pcm,
            timeout=300,
        )
        ended = time.monotonic_ns()
        self.resources.checkpoint("baseline_foreground_complete")
        metadata = response.decoded_metadata()
        if response.kind != Kind.RESULT:
            raise HarnessFailure("foreground baseline did not return RESULT")
        return RealTrialResult(
            observation=TrialObservation(
                arm="baseline",
                stop_offset_ms=offset_ms,
                stop_to_result_ns=ended - started,
                kill_to_reap_ns=None,
                speculative_pid=None,
                completed_cache_count=0,
                adopted_cache_count=int(metadata["adopted_cache_count"]),
                ordinary_final_invocations=int(metadata["ordinary_final_invocations"]),
                result=AuditedResult.from_dict(metadata["result"]),
                foreground_request_monotonic_ns=started,
            ),
            reload_wall_ns=None,
            peak_combined_footprint_bytes=self.resources.peak_combined_resident_bytes,
            active_kill=False,
        )

    async def stop_during_replacement_prepare(
        self,
        *,
        pcm: bytes,
        trial_id: str,
        storage_id: str,
        stop_after_ms: int,
    ) -> PrepareInterruptionObservation:
        if not 1_000 <= stop_after_ms <= 10_000:
            raise HarnessFailure("real replacement-PREPARE stop must be within 1-10 s")
        speculative = WorkerProcess(
            self.worker_command,
            role="speculative",
            expected_identity=self.expected_identity,
            environment=self.environment,
        )
        await speculative.launch()
        generation = speculative.generation
        if generation is None:
            raise HarnessFailure("replacement generation disappeared after launch")
        self._register_speculative("replacement_stop", speculative)
        self.resources.checkpoint("replacement_stop_launched")
        await self.foreground.mark_process_exit(
            operation="arm_process_exit",
            trial_id=trial_id,
            trial_tag=trial_tag(trial_id),
            speculative_generation=generation,
        )
        self.markers.record(
            "replacement_exit_observer_armed",
            trial_id=trial_id,
            pid=generation.pid,
            generation=generation.token,
            trial_tag=trial_tag(trial_id),
            observer_pid=self.foreground.pid,
            stop_after_ms=stop_after_ms,
        )
        _, prepare_started = await speculative.begin_prepare_for_trial(
            timeout=5,
            trial_id=trial_id,
            stage="protocol_containment",
            hold_after_started_ms=stop_after_ms + 1_000,
        )
        self.resources.checkpoint("replacement_prepare_started_ack")
        self.markers.record(
            "replacement_prepare_started_ack",
            trial_id=trial_id,
            pid=generation.pid,
            generation=generation.token,
            trial_tag=trial_tag(trial_id),
            stage=str(prepare_started["stage"]),
            worker_started_monotonic_ns=int(
                prepare_started["prepare_started_monotonic_ns"]
            ),
            evidence_scope="protocol_containment_before_native_model_creation",
        )
        try:
            await asyncio.sleep(stop_after_ms / 1_000)
            stop_started = time.monotonic_ns()
            self.resources.checkpoint("replacement_prepare_pre_kill")
            # Do not issue libproc reads against a dying PID. The continuous
            # series ends at this explicit pre-kill checkpoint; the following
            # gap is covered by exact waitpid markers plus DISPATCH_PROC_EXIT.
            self.resources.retire_if_tracked("replacement_stop", speculative)
            kill_to_reap_ns = await speculative.kill_and_reap(timeout=1.0)
            self._forget_speculative("replacement_stop", speculative)
            reap = speculative.last_reap_markers
            if reap is None or reap.sigkill_monotonic_ns is None or reap.return_code != -9:
                raise HarnessFailure("replacement PREPARE lacked exact SIGKILL/waitpid")
            if kill_to_reap_ns > REAP_DEADLINE_NS:
                raise HarnessFailure("replacement PREPARE reap exceeded 250 ms")
            observed_started = time.monotonic_ns()
            await self.foreground.mark_process_exit(
                operation="await_process_exit",
                trial_id=trial_id,
                trial_tag=trial_tag(trial_id),
                speculative_generation=generation,
            )
            observed_ended = time.monotonic_ns()
            if kill_to_reap_ns + (observed_ended - observed_started) > REAP_DEADLINE_NS:
                raise HarnessFailure("SIGKILL through kernel exit observation exceeded 250 ms")
            self.resources.checkpoint("replacement_prepare_post_kill")
            self.reaped_pids.append(generation.pid)
            self.markers.record(
                "replacement_prepare_sigkill_waitpid",
                trial_id=trial_id,
                pid=generation.pid,
                generation=generation.token,
                trial_tag=trial_tag(trial_id),
                observer_pid=self.foreground.pid,
                stop_after_ms=stop_after_ms,
                sigkill_monotonic_ns=reap.sigkill_monotonic_ns,
                waitpid_monotonic_ns=reap.waitpid_monotonic_ns,
                reap_duration_ns=kill_to_reap_ns,
                process_return_code=reap.return_code,
                observation_wait_ns=observed_ended - observed_started,
                prepare_stage=str(prepare_started["stage"]),
                evidence_scope="protocol_containment_not_native_coreml_active",
            )

            foreground_started = time.monotonic_ns()
            if foreground_started < reap.waitpid_monotonic_ns:
                raise HarnessFailure("N+1 F request preceded replacement waitpid")
            self.markers.record(
                "foreground_request",
                arm="prepare_interruption",
                trial_id=trial_id,
                pid=self.foreground.pid,
                trial_tag=trial_tag(trial_id),
                request_monotonic_ns=foreground_started,
                preceding_waitpid_monotonic_ns=reap.waitpid_monotonic_ns,
            )
            response = await self.foreground.request(
                Kind.TRANSCRIBE,
                {
                    "trial_id": trial_id,
                    "capture_storage_id": storage_id,
                    "speculative_generation": None,
                    "cache_count": 0,
                },
                pcm,
                timeout=300,
            )
            ended = time.monotonic_ns()
            self.resources.checkpoint("replacement_prepare_foreground_complete")
            if response.kind != Kind.RESULT:
                raise HarnessFailure("N+1 foreground did not return RESULT")
            metadata = response.decoded_metadata()
            return PrepareInterruptionObservation(
                stop_after_ms=stop_after_ms,
                stop_to_result_ns=ended - stop_started,
                kill_to_reap_ns=kill_to_reap_ns,
                speculative_pid=generation.pid,
                sigkill_monotonic_ns=reap.sigkill_monotonic_ns,
                waitpid_monotonic_ns=reap.waitpid_monotonic_ns,
                foreground_request_monotonic_ns=foreground_started,
                ordinary_final_invocations=int(metadata["ordinary_final_invocations"]),
                result=AuditedResult.from_dict(metadata["result"]),
                prepare_stage=str(prepare_started["stage"]),
                prepare_started_monotonic_ns=int(
                    prepare_started["prepare_started_monotonic_ns"]
                ),
                native_coreml_active_proven=False,
            )
        except BaseException:
            if speculative.process is not None:
                self.resources.retire_if_tracked("replacement_stop", speculative)
                await speculative.kill_and_reap(allow_already_exited=True)
                self._forget_speculative("replacement_stop", speculative)
            raise

    async def dual(
        self,
        *,
        pcm: bytes,
        trial_id: str,
        storage_id: str,
        offset_ms: int,
    ) -> RealTrialResult:
        speculative = WorkerProcess(
            self.worker_command,
            role="speculative",
            expected_identity=self.expected_identity,
            environment=self.environment,
        )
        launched = time.monotonic_ns()
        await speculative.launch()
        self._register_speculative("speculative", speculative)
        self.resources.checkpoint("speculative_launched")
        generation = speculative.generation
        if generation is None:
            raise HarnessFailure("speculative generation disappeared after launch")
        await self.foreground.mark_process_exit(
            operation="arm_process_exit",
            trial_id=trial_id,
            trial_tag=trial_tag(trial_id),
            speculative_generation=generation,
        )
        self.markers.record(
            "speculative_exit_observer_armed",
            trial_id=trial_id,
            pid=generation.pid,
            generation=generation.token,
            trial_tag=trial_tag(trial_id),
            observer_pid=self.foreground.pid,
        )
        ready = await speculative.prepare_for_trial(timeout=90, trial_id=trial_id)
        self.resources.checkpoint("speculative_model_ready")
        self.markers.record(
            "speculative_model_ready",
            trial_id=trial_id,
            pid=generation.pid,
            generation=generation.token,
            launch_monotonic_ns=launched,
            worker_ready_monotonic_ns=int(ready["model_ready_monotonic_ns"]),
        )
        completed: list[SerializedClosedWindowCache] = []
        target_started: int | None = None
        active_window_index: int | None = None
        request_id = await speculative.send(
            Kind.SPECULATE,
            {
                "trial_id": trial_id,
                "capture_storage_id": storage_id,
                "speculative_generation": generation.token,
            },
            pcm,
        )
        while target_started is None:
            frame = await speculative.receive(timeout=120)
            if frame.request_id != request_id:
                raise HarnessFailure("speculative event request id mismatch")
            if frame.kind == Kind.CACHE_RECORD:
                completed.append(
                    SerializedClosedWindowCache.from_parts(
                        frame.decoded_metadata(), frame.payload
                    )
                )
            elif frame.kind == Kind.PREDICTION_STARTED:
                marker = frame.decoded_metadata()
                active_window_index = int(marker["window_index"])
                self.markers.record(
                    "prediction_started",
                    trial_id=trial_id,
                    pid=speculative.pid,
                    generation=generation.token,
                    worker_monotonic_ns=int(marker["monotonic_ns"]),
                    window_index=int(marker["window_index"]),
                    trial_tag=int(marker["trial_tag"]),
                )
                if completed:
                    target_started = time.monotonic_ns()
                    self.resources.checkpoint("prediction_started")
            elif frame.kind == Kind.PREDICTION_COMPLETED:
                marker = frame.decoded_metadata()
                completed_window_index = int(marker["window_index"])
                if active_window_index != completed_window_index:
                    raise HarnessFailure("prediction completion crossed active window")
                active_window_index = None
                self.markers.record(
                    "prediction_completed",
                    trial_id=trial_id,
                    pid=speculative.pid,
                    generation=generation.token,
                    worker_monotonic_ns=int(marker["monotonic_ns"]),
                    window_index=int(marker["window_index"]),
                    trial_tag=int(marker["trial_tag"]),
                )
                self.resources.checkpoint("prediction_completed")
            elif frame.kind == Kind.FAILURE:
                raise HarnessFailure(f"speculative failure: {frame.decoded_metadata()}")
            elif frame.kind == Kind.ACK:
                raise HarnessFailure("speculation completed before an eligible active window")
            else:
                raise HarnessFailure(f"unexpected speculative frame {frame.kind.name}")

        deadline = target_started + offset_ms * 1_000_000
        speculation_finished = False
        while time.monotonic_ns() < deadline:
            remaining = (deadline - time.monotonic_ns()) / 1_000_000_000
            try:
                frame = await speculative.receive(timeout=max(0.000_001, remaining))
            except HarnessFailure:
                break
            if frame.request_id != request_id:
                raise HarnessFailure("speculative event request id mismatch after target")
            if frame.kind == Kind.CACHE_RECORD:
                completed.append(
                    SerializedClosedWindowCache.from_parts(
                        frame.decoded_metadata(), frame.payload
                    )
                )
            elif frame.kind in (Kind.PREDICTION_STARTED, Kind.PREDICTION_COMPLETED):
                marker = frame.decoded_metadata()
                marker_window_index = int(marker["window_index"])
                if frame.kind == Kind.PREDICTION_STARTED:
                    if active_window_index is not None:
                        raise HarnessFailure("prediction start overlapped active window")
                    active_window_index = marker_window_index
                else:
                    if active_window_index != marker_window_index:
                        raise HarnessFailure("prediction completion crossed active window")
                    active_window_index = None
                self.markers.record(
                    frame.kind.name.lower(),
                    trial_id=trial_id,
                    pid=speculative.pid,
                    generation=generation.token,
                    worker_monotonic_ns=int(marker["monotonic_ns"]),
                    window_index=int(marker["window_index"]),
                    trial_tag=int(marker["trial_tag"]),
                )
                self.resources.checkpoint(frame.kind.name.lower())
            elif frame.kind == Kind.ACK:
                speculation_finished = True
                break
            elif frame.kind == Kind.FAILURE:
                raise HarnessFailure(f"speculative failure: {frame.decoded_metadata()}")

        stop_started = time.monotonic_ns()
        active_kill = not speculation_finished
        kill_to_reap_ns: int | None = None
        waitpid_ns: int | None = None
        if active_kill:
            if active_window_index is None:
                raise HarnessFailure("stop landed between speculative prediction windows")
            self.resources.checkpoint("pre_kill")
            # Sampling deliberately stops at pre_kill; kernel lifecycle proof
            # covers SIGKILL through process-exit observation without racing
            # libproc against PID teardown.
            self.resources.retire_if_tracked("speculative", speculative)
            kill_to_reap_ns = await speculative.kill_and_reap(timeout=1.0)
            self._forget_speculative("speculative", speculative)
            self.resources.checkpoint("post_kill")
            reap = speculative.last_reap_markers
            if reap is None or reap.sigkill_monotonic_ns is None:
                raise HarnessFailure("active S lacked exact SIGKILL/waitpid markers")
            waitpid_ns = reap.waitpid_monotonic_ns
            self.reaped_pids.append(generation.pid)
            self.markers.record(
                "speculative_sigkill_waitpid",
                trial_id=trial_id,
                pid=generation.pid,
                generation=generation.token,
                sigkill_monotonic_ns=reap.sigkill_monotonic_ns,
                waitpid_monotonic_ns=reap.waitpid_monotonic_ns,
                reap_duration_ns=kill_to_reap_ns,
                process_return_code=reap.return_code,
                trial_tag=trial_tag(trial_id),
                active_window_index=active_window_index,
            )
            if kill_to_reap_ns > REAP_DEADLINE_NS:
                raise HarnessFailure("active S reap exceeded 250 ms")
            observed_started = time.monotonic_ns()
            await self.foreground.mark_process_exit(
                operation="await_process_exit",
                trial_id=trial_id,
                trial_tag=trial_tag(trial_id),
                speculative_generation=generation,
            )
            observed_ended = time.monotonic_ns()
            if kill_to_reap_ns + (observed_ended - observed_started) > REAP_DEADLINE_NS:
                raise HarnessFailure("SIGKILL through kernel exit observation exceeded 250 ms")
            self.markers.record(
                "speculative_process_exit_observed",
                trial_id=trial_id,
                pid=generation.pid,
                generation=generation.token,
                trial_tag=trial_tag(trial_id),
                observer_pid=self.foreground.pid,
                observation_wait_ns=observed_ended - observed_started,
            )
        else:
            before = speculative.generation
            first = await speculative.probe_idle()
            second = await speculative.probe_idle()
            if before != first or first != second:
                raise HarnessFailure("idle S was not reused")
            self.markers.record(
                "speculative_idle_reused",
                trial_id=trial_id,
                pid=first.pid,
                generation=first.token,
            )
            self.resources.checkpoint("speculation_completed_idle")

        for record in completed:
            response = await self.foreground.request(
                Kind.CACHE_RECORD,
                record.metadata_dict(),
                record.exact_input_pcm,
                timeout=10,
            )
            if response.kind != Kind.ACK:
                raise HarnessFailure("foreground cache transfer was not ACKed")

        foreground_started = time.monotonic_ns()
        if waitpid_ns is not None and foreground_started < waitpid_ns:
            raise HarnessFailure("foreground request preceded exact waitpid")
        self.markers.record(
            "foreground_request",
            arm="dual",
            trial_id=trial_id,
            pid=self.foreground.pid,
            trial_tag=trial_tag(trial_id),
            request_monotonic_ns=foreground_started,
            preceding_waitpid_monotonic_ns=waitpid_ns,
        )
        response = await self.foreground.request(
            Kind.TRANSCRIBE,
            {
                "trial_id": trial_id,
                "capture_storage_id": storage_id,
                "speculative_generation": generation.token,
                "cache_count": len(completed),
            },
            pcm,
            timeout=300,
        )
        ended = time.monotonic_ns()
        self.resources.checkpoint("foreground_complete")
        self.resources.checkpoint("post_complete")
        metadata = response.decoded_metadata()
        if response.kind != Kind.RESULT:
            raise HarnessFailure("foreground dual arm did not return RESULT")
        if int(metadata["trial_tag"]) != trial_tag(trial_id):
            raise HarnessFailure("foreground worker trial signpost tag mismatch")

        reload_wall_ns: int | None = None
        if active_kill:
            replacement = WorkerProcess(
                self.worker_command,
                role="speculative",
                expected_identity=self.expected_identity,
                environment=self.environment,
            )
            reload_started = time.monotonic_ns()
            await replacement.launch()
            self._register_speculative("replacement", replacement)
            self.resources.checkpoint("replacement_launched")
            replacement_ready = await replacement.prepare_for_trial(
                timeout=90,
                trial_id=f"{trial_id}-reload",
            )
            reload_wall_ns = time.monotonic_ns() - reload_started
            self.resources.checkpoint("replacement_model_ready")
            self.markers.record(
                "speculative_cold_reload_ready",
                trial_id=trial_id,
                pid=replacement.pid,
                reload_started_monotonic_ns=reload_started,
                worker_ready_monotonic_ns=int(
                    replacement_ready["model_ready_monotonic_ns"]
                ),
                reload_wall_ns=reload_wall_ns,
                next_eligibility_ns=51_840_000_000,
            )
            await replacement.shutdown()
            self._forget_speculative("replacement", replacement)
            if reload_wall_ns >= 51_840_000_000:
                raise HarnessFailure("S cold reload missed next-session eligibility")
        else:
            await speculative.shutdown()
            self._forget_speculative("speculative", speculative)
            await self.foreground.mark_process_exit(
                operation="await_process_exit",
                trial_id=trial_id,
                trial_tag=trial_tag(trial_id),
                speculative_generation=generation,
            )

        return RealTrialResult(
            observation=TrialObservation(
                arm="dual",
                stop_offset_ms=offset_ms,
                stop_to_result_ns=ended - stop_started,
                kill_to_reap_ns=kill_to_reap_ns,
                speculative_pid=generation.pid,
                completed_cache_count=len(completed),
                adopted_cache_count=int(metadata["adopted_cache_count"]),
                ordinary_final_invocations=int(metadata["ordinary_final_invocations"]),
                result=AuditedResult.from_dict(metadata["result"]),
                prediction_started_monotonic_ns=target_started,
                sigkill_monotonic_ns=(
                    speculative.last_reap_markers.sigkill_monotonic_ns
                    if speculative.last_reap_markers
                    else None
                ),
                waitpid_monotonic_ns=waitpid_ns,
                foreground_request_monotonic_ns=foreground_started,
            ),
            reload_wall_ns=reload_wall_ns,
            peak_combined_footprint_bytes=self.resources.peak_combined_resident_bytes,
            active_kill=active_kill,
        )


def _percentile(values: Iterable[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return float("nan")
    index = max(0, min(len(ordered) - 1, int((len(ordered) * fraction) + 0.999999) - 1))
    return ordered[index]


async def _run_model_preflight_inner(
    *,
    worker: Path,
    spec_path: Path,
    fixture: Path,
    fixture_repeat: int,
    offsets: Sequence[int],
    n_per_arm: int,
    authorization_token: str,
    markers_path: Path,
    resource_series_path: Path,
) -> dict[str, Any]:
    if fixture_repeat <= 0:
        raise HarnessFailure("fixture repeat must be positive")
    identity, spec = load_real_identity(worker=worker, spec_path=spec_path)
    if hashlib.sha256(authorization_token.encode()).hexdigest() != spec[
        "authorization_token_sha256"
    ]:
        raise HarnessFailure("controller GO token does not match reviewed spec")
    source_pcm = fixture.resolve(strict=True).read_bytes()
    pcm = source_pcm * fixture_repeat
    if not pcm or len(pcm) % 4:
        raise HarnessFailure("fixture must be nonempty native Float32")
    sample_count = len(pcm) // 4
    if not FIRST_WAVE_REDUCING_SAMPLES <= sample_count <= MAX_FINAL_SAMPLES:
        raise HarnessFailure("fixture is outside 51.84 s through 5 min preflight bounds")

    command = (
        str(worker.resolve(strict=True)),
        "--spec",
        str(spec_path.resolve(strict=True)),
        "--allow-coreml-after-explicit-go",
    )
    environment = {
        "DCHF_COREML_GO_TOKEN": authorization_token,
        "DCHF_ALLOW_PROTOCOL_CONTAINMENT_GATE": "1",
    }
    markers = MarkerRecorder(markers_path)
    resources = BoundedResourceSampler(
        interval_seconds=0.010,
        limit_bytes=COMBINED_FOOTPRINT_LIMIT,
    )
    foreground = WorkerProcess(
        command,
        role="foreground",
        expected_identity=identity,
        environment=environment,
    )
    try:
        await foreground.launch()
        resources.track("foreground", foreground)
        await resources.start()
        resources.checkpoint("foreground_prepare_start")
        foreground_ready = await foreground.prepare_for_trial(
            timeout=90,
            trial_id="foreground-initial-prepare",
        )
        resources.checkpoint("foreground_model_ready")
        initial_foreground = foreground.resource_snapshot()
        markers.record(
            "foreground_model_ready",
            pid=foreground.pid,
            worker_ready_monotonic_ns=int(foreground_ready["model_ready_monotonic_ns"]),
        )
    except BaseException:
        try:
            resources.retire_if_tracked("foreground", foreground)
            if foreground.process is not None:
                await foreground.kill_and_reap(allow_already_exited=True)
        finally:
            try:
                await resources.stop()
            finally:
                resources.write_jsonl(resource_series_path)
                markers.close()
        raise
    runner = RealPreflightRunner(
        foreground=foreground,
        worker_command=command,
        expected_identity=identity,
        environment=environment,
        markers=markers,
        resources=resources,
    )
    results: list[RealTrialResult] = []
    prepare_interruptions: list[PrepareInterruptionObservation] = []
    prepare_interruption_baselines: list[RealTrialResult] = []
    reference: AuditedResult | None = None
    try:
        # Product control: an idle, prepared S survives two stop boundaries.
        idle = WorkerProcess(
            command,
            role="speculative",
            expected_identity=identity,
            environment=environment,
        )
        await idle.launch()
        runner._register_speculative("idle_control", idle)
        resources.checkpoint("idle_control_launched")
        await idle.prepare_for_trial(timeout=90, trial_id="idle-control-prepare")
        resources.checkpoint("idle_control_model_ready")
        original = idle.generation
        first = await idle.probe_idle()
        second = await idle.probe_idle()
        if original != first or first != second:
            raise HarnessFailure("idle S control changed PID/generation")
        markers.record(
            "idle_control_reused",
            pid=first.pid,
            generation=first.token,
            boundaries=2,
        )
        await idle.shutdown()
        runner._forget_speculative("idle_control", idle)

        # Product N+1 may stop while replacement S is not ready. A bounded,
        # explicitly gated hold immediately after the real worker emits
        # PREPARE_STARTED makes lifecycle containment deterministic. This case
        # deliberately does not claim native CoreML load/warm was active.
        for stop_after_ms in (1_000,):
            short_pcm = pcm[: stop_after_ms * 16 * 4]
            baseline_trial = f"prepare-baseline-{stop_after_ms}-{uuid.uuid4()}"
            baseline_result = await runner.baseline(
                pcm=short_pcm,
                trial_id=baseline_trial,
                storage_id=str(uuid.uuid4()),
                offset_ms=stop_after_ms,
            )
            interruption_trial = f"prepare-interruption-{stop_after_ms}-{uuid.uuid4()}"
            interrupted = await runner.stop_during_replacement_prepare(
                pcm=short_pcm,
                trial_id=interruption_trial,
                storage_id=str(uuid.uuid4()),
                stop_after_ms=stop_after_ms,
            )
            baseline_result.observation.result.assert_exact_parity(interrupted.result)
            if interrupted.ordinary_final_invocations != 1:
                raise HarnessFailure("N+1 fallback did not invoke ordinary final exactly once")
            if (
                interrupted.stop_to_result_ns
                > baseline_result.observation.stop_to_result_ns + REAP_DEADLINE_NS
            ):
                raise HarnessFailure("N+1 prepare interruption exceeded baseline + 250 ms")
            prepare_interruption_baselines.append(baseline_result)
            prepare_interruptions.append(interrupted)

        for ordinal, (arm, offset) in enumerate(symmetric_arm_order(offsets, n_per_arm)):
            trial_id = f"real-{ordinal}-{uuid.uuid4()}"
            storage_id = str(uuid.uuid4())
            if arm == "baseline":
                result = await runner.baseline(
                    pcm=pcm,
                    trial_id=trial_id,
                    storage_id=storage_id,
                    offset_ms=offset,
                )
            else:
                result = await runner.dual(
                    pcm=pcm,
                    trial_id=trial_id,
                    storage_id=storage_id,
                    offset_ms=offset,
                )
                if result.observation.adopted_cache_count <= 0:
                    raise HarnessFailure("dual arm did not adopt a completed exact cache")
            if reference is None:
                reference = result.observation.result
            else:
                reference.assert_exact_parity(result.observation.result)
            if result.peak_combined_footprint_bytes >= COMBINED_FOOTPRINT_LIMIT:
                raise HarnessFailure("combined F+S physical footprint reached 12 GiB")
            results.append(result)
        final_foreground = foreground.resource_snapshot()
    finally:
        try:
            await runner.cleanup_speculative()
        finally:
            try:
                try:
                    resources.checkpoint("foreground_before_shutdown")
                finally:
                    await resources.stop()
            finally:
                try:
                    resources.write_jsonl(resource_series_path)
                    resources.retire_if_tracked("foreground", foreground)
                    if foreground.process is not None:
                        await foreground.shutdown()
                finally:
                    markers.close()

    for pid in runner.reaped_pids:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        raise HarnessFailure(f"orphan speculative PID {pid}")
    fd_growth = final_foreground.descriptor_count - initial_foreground.descriptor_count
    if fd_growth > 2:
        raise HarnessFailure(f"foreground FD growth {fd_growth} exceeds 2")
    if not any(item.active_kill for item in results if item.observation.arm == "dual"):
        raise HarnessFailure("preflight did not exercise active SIGKILL/waitpid")

    arms: dict[str, Any] = {}
    for arm in ("baseline", "dual"):
        durations = [
            item.observation.stop_to_result_ns / 1_000_000
            for item in results
            if item.observation.arm == arm
        ]
        arms[arm] = {
            "count": len(durations),
            "median_ms": statistics.median(durations),
            "p95_ms": _percentile(durations, 0.95),
            "max_ms": max(durations),
        }
    latency_pass = (
        arms["dual"]["p95_ms"] < arms["baseline"]["p95_ms"]
        and arms["dual"]["max_ms"] < arms["baseline"]["max_ms"]
    )
    if not latency_pass:
        raise HarnessFailure("dual preflight did not beat baseline p95 and max")

    reloads = [item.reload_wall_ns for item in results if item.reload_wall_ns is not None]
    return {
        "backend": "real-dual-process",
        "identity_sha256": identity.canonical_sha256,
        "fixture_sha256": hashlib.sha256(pcm).hexdigest(),
        "sample_count": sample_count,
        "offsets_ms": list(offsets),
        "n_per_arm": n_per_arm,
        "full_exact_parity": True,
        "ordinary_and_cached_same_artifact": True,
        "active_kill_count": sum(item.active_kill for item in results),
        "max_reap_ms": max(
            (item.observation.kill_to_reap_ns or 0) / 1_000_000 for item in results
        ),
        "cold_reload_wall_ms": [value / 1_000_000 for value in reloads],
        "reload_before_51_84s_eligibility": all(
            value < 51_840_000_000 for value in reloads
        ),
        "replacement_prepare_stop_cases": [
            {
                "stop_after_ms": interrupted.stop_after_ms,
                "kill_to_reap_ms": interrupted.kill_to_reap_ns / 1_000_000,
                "stop_to_result_ms": interrupted.stop_to_result_ns / 1_000_000,
                "ordinary_baseline_stop_to_result_ms": baseline.observation.stop_to_result_ns
                / 1_000_000,
                "latency_budget_ms": (
                    baseline.observation.stop_to_result_ns + REAP_DEADLINE_NS
                )
                / 1_000_000,
                "full_exact_parity": True,
                "ordinary_final_invocations": interrupted.ordinary_final_invocations,
                "prepare_stage": interrupted.prepare_stage,
                "native_coreml_active_proven": interrupted.native_coreml_active_proven,
            }
            for baseline, interrupted in zip(
                prepare_interruption_baselines,
                prepare_interruptions,
                strict=True,
            )
        ],
        "foreground_fd_growth": fd_growth,
        "peak_combined_phys_footprint_bytes": resources.peak_combined_resident_bytes,
        "resource_sample_interval_ms": resources.interval_seconds * 1_000,
        "resource_sample_count": len(resources.samples),
        "resource_series": str(resource_series_path),
        "speculative_orphans": 0,
        "max_live_children": 2,
        "arms": arms,
        "latency_gate": "p95_and_max_strictly_better",
        "trace_gate": "PENDING_XCTRACE_ACCEPTANCE",
        "markers": str(markers_path),
    }


async def run_model_preflight(
    *,
    worker: Path,
    spec_path: Path,
    fixture: Path,
    fixture_repeat: int,
    offsets: Sequence[int],
    n_per_arm: int,
    authorization_token: str,
    markers_path: Path,
    resource_series_path: Path,
) -> dict[str, Any]:
    """Run the model lane inside an independently recorded OS-memory gate."""

    memory_report_path = resource_series_path.with_name(
        resource_series_path.stem + ".system-memory.json"
    )
    pre: SystemMemorySnapshot | None = None
    post: SystemMemorySnapshot | None = None
    try:
        pre = capture_system_memory_snapshot()
        validate_system_memory_gate(pre)
    except BaseException as error:
        write_system_memory_report(
            memory_report_path,
            pre=pre,
            post=None,
            error=str(error),
        )
        raise
    write_system_memory_report(
        memory_report_path,
        pre=pre,
        post=None,
        error="model preflight has not completed",
    )

    result: dict[str, Any] | None = None
    model_error: BaseException | None = None
    try:
        result = await _run_model_preflight_inner(
            worker=worker,
            spec_path=spec_path,
            fixture=fixture,
            fixture_repeat=fixture_repeat,
            offsets=offsets,
            n_per_arm=n_per_arm,
            authorization_token=authorization_token,
            markers_path=markers_path,
            resource_series_path=resource_series_path,
        )
    except BaseException as error:
        model_error = error

    memory_error: BaseException | None = None
    try:
        post = capture_system_memory_snapshot()
        validate_system_memory_gate(pre, post)
    except BaseException as error:
        memory_error = error
    write_system_memory_report(
        memory_report_path,
        pre=pre,
        post=post,
        error=str(memory_error or model_error) if memory_error or model_error else None,
    )

    if model_error is not None and memory_error is not None:
        raise HarnessFailure(
            f"model preflight failed ({model_error}); postflight memory gate also failed "
            f"({memory_error})"
        ) from model_error
    if model_error is not None:
        raise model_error
    if memory_error is not None:
        raise memory_error
    assert result is not None and post is not None
    result["system_memory_report"] = str(memory_report_path)
    result["swap_delta_bytes"] = post.swap_used_bytes - pre.swap_used_bytes
    result["memory_pressure_pre"] = pre.pressure_level
    result["memory_pressure_post"] = post.pressure_level
    result["memory_pressure_gate"] = "normal_pre_and_post"
    return result
