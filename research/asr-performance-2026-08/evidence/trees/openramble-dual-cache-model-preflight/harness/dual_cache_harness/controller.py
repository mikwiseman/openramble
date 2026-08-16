from __future__ import annotations

import asyncio
import ctypes
import dataclasses
import hashlib
import json
import os
import platform
import signal
import struct
import subprocess
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

from .schema import (
    AuditedResult,
    ExecutionIdentity,
    SerializedClosedWindowCache,
)
from .wire import Frame, Kind, WireError, read_async, write_async


class HarnessFailure(RuntimeError):
    pass


def exact_trial_tag(trial_id: str) -> int:
    return int.from_bytes(hashlib.sha256(trial_id.encode()).digest()[:8], "big")


@dataclass(frozen=True)
class ExactProcessGeneration:
    token: str
    pid: int


@dataclass(frozen=True)
class ProcessResourceSnapshot:
    pid: int
    resident_bytes: int
    descriptor_count: int


@dataclass(frozen=True)
class ResourceSeriesSample:
    monotonic_ns: int
    label: str
    processes: tuple[ProcessResourceSnapshot, ...]

    @property
    def combined_resident_bytes(self) -> int:
        return sum(item.resident_bytes for item in self.processes)


@dataclass(frozen=True)
class ReapMarkers:
    generation: ExactProcessGeneration
    sigkill_monotonic_ns: int | None
    waitpid_monotonic_ns: int
    return_code: int


@dataclass(frozen=True)
class TrialObservation:
    arm: str
    stop_offset_ms: int
    stop_to_result_ns: int
    kill_to_reap_ns: int | None
    speculative_pid: int | None
    completed_cache_count: int
    adopted_cache_count: int
    ordinary_final_invocations: int
    result: AuditedResult
    prediction_started_monotonic_ns: int | None = None
    sigkill_monotonic_ns: int | None = None
    waitpid_monotonic_ns: int | None = None
    foreground_request_monotonic_ns: int | None = None


@dataclass(frozen=True)
class PrepareInterruptionObservation:
    stop_after_ms: int
    stop_to_result_ns: int
    kill_to_reap_ns: int
    speculative_pid: int
    sigkill_monotonic_ns: int
    waitpid_monotonic_ns: int
    foreground_request_monotonic_ns: int
    ordinary_final_invocations: int
    result: AuditedResult
    prepare_stage: str
    prepare_started_monotonic_ns: int
    native_coreml_active_proven: bool


class WorkerProcess:
    """One exact child generation with bounded framed request/response I/O."""

    def __init__(
        self,
        command: Sequence[str],
        *,
        role: str,
        expected_identity: ExecutionIdentity,
        environment: Mapping[str, str] | None = None,
    ) -> None:
        self.command = tuple(command)
        self.role = role
        self.expected_identity = expected_identity
        self.environment = dict(environment or {})
        self.process: asyncio.subprocess.Process | None = None
        self.generation: ExactProcessGeneration | None = None
        self._next_request_id = 1
        self._lock = asyncio.Lock()
        self._pending_prepare: tuple[
            int, ExactProcessGeneration, str, str
        ] | None = None
        self._poisoned = False
        self.last_reap_markers: ReapMarkers | None = None

    async def launch(self) -> None:
        if self.process is not None:
            raise HarnessFailure("worker generation is already launched")
        environment = os.environ.copy()
        environment.update(self.environment)
        environment["DCHF_ROLE"] = self.role
        process = await asyncio.create_subprocess_exec(
            *self.command,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=environment,
            start_new_session=True,
        )
        self.process = process
        self.generation = ExactProcessGeneration(token=str(uuid.uuid4()), pid=process.pid)
        self._poisoned = False
        try:
            response = await self.request(
                Kind.HELLO,
                {
                    "role": self.role,
                    "generation": self.generation.token,
                    "expected_identity": self.expected_identity.to_dict(),
                },
            )
        except BaseException:
            await self.kill_and_reap(allow_already_exited=True)
            raise
        if response.kind != Kind.HELLO_ACK:
            await self.kill_and_reap()
            raise HarnessFailure(f"{self.role} did not acknowledge hello")
        actual = ExecutionIdentity.from_dict(response.decoded_metadata()["identity"])
        if actual != self.expected_identity:
            await self.kill_and_reap()
            raise HarnessFailure(f"{self.role} execution identity mismatch")

    @property
    def pid(self) -> int:
        if self.generation is None:
            raise HarnessFailure("worker is not launched")
        return self.generation.pid

    def _streams(self) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
        if self.process is None or self.process.stdout is None or self.process.stdin is None:
            raise HarnessFailure("worker is not launched")
        return self.process.stdout, self.process.stdin

    async def send(
        self,
        kind: Kind,
        metadata: Mapping[str, Any],
        payload: bytes = b"",
        *,
        request_id: int | None = None,
    ) -> int:
        _, writer = self._streams()
        if request_id is None:
            request_id = self._next_request_id
            self._next_request_id += 1
        await write_async(writer, Frame.json(kind, request_id, metadata, payload))
        return request_id

    async def receive(self, *, timeout: float = 2.0) -> Frame:
        reader, _ = self._streams()
        try:
            frame = await asyncio.wait_for(read_async(reader), timeout=timeout)
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, EOFError, WireError) as error:
            raise HarnessFailure(f"{self.role} pipe receive failed: {error}") from error
        if frame is None:
            raise HarnessFailure(f"{self.role} closed its output pipe")
        return frame

    async def request(
        self,
        kind: Kind,
        metadata: Mapping[str, Any],
        payload: bytes = b"",
        *,
        timeout: float = 2.0,
    ) -> Frame:
        async with self._lock:
            if self._poisoned:
                raise HarnessFailure(f"{self.role} generation is transport-poisoned")
            if self._pending_prepare is not None:
                raise HarnessFailure(
                    f"{self.role} has an unfinished staged PREPARE response"
                )
            request_id = await self.send(kind, metadata, payload)
            try:
                frame = await self.receive(timeout=timeout)
            except BaseException:
                self._poisoned = True
                raise
            if frame.request_id != request_id:
                self._poisoned = True
                raise HarnessFailure(
                    f"{self.role} response id {frame.request_id} != {request_id}"
                )
            if frame.kind == Kind.FAILURE:
                raise HarnessFailure(
                    f"{self.role} failure: {frame.decoded_metadata().get('error', 'unknown')}"
                )
            return frame

    async def kill_and_reap(
        self,
        *,
        timeout: float = 1.0,
        allow_already_exited: bool = False,
    ) -> int:
        """Kill this Process object only; PID discovery/globs are forbidden."""

        process = self.process
        generation = self.generation
        if process is None or generation is None:
            return 0
        started = time.perf_counter_ns()
        sigkill_ns: int | None = None
        if process.returncode is None:
            process.kill()
            sigkill_ns = time.monotonic_ns()
        try:
            return_code = await asyncio.wait_for(process.wait(), timeout=timeout)
        except asyncio.TimeoutError as error:
            raise HarnessFailure(
                f"exact worker generation {generation.token}/{generation.pid} did not reap"
            ) from error
        if process.stdin is not None:
            process.stdin.close()
        self.process = None
        self.generation = None
        self._pending_prepare = None
        self._poisoned = False
        waitpid_ns = time.monotonic_ns()
        self.last_reap_markers = ReapMarkers(
            generation=generation,
            sigkill_monotonic_ns=sigkill_ns,
            waitpid_monotonic_ns=waitpid_ns,
            return_code=return_code,
        )
        if return_code not in (-signal.SIGKILL, 0) and not allow_already_exited:
            raise HarnessFailure(f"unexpected killed-worker return code {return_code}")
        return time.perf_counter_ns() - started

    async def shutdown(self) -> None:
        process = self.process
        if process is None:
            return
        try:
            response = await self.request(Kind.SHUTDOWN, {}, timeout=1.0)
            if response.kind != Kind.ACK:
                raise HarnessFailure("shutdown was not acknowledged")
            await asyncio.wait_for(process.wait(), timeout=1.0)
            if process.stdin is not None:
                process.stdin.close()
            self.process = None
            self.generation = None
            self._pending_prepare = None
            self._poisoned = False
        except Exception:
            await self.kill_and_reap()
            raise

    async def probe_idle(self) -> ExactProcessGeneration:
        """Prove an idle generation remains the same process, not a reload."""

        before = self.generation
        if before is None:
            raise HarnessFailure("worker is not launched")
        response = await self.request(Kind.PING, {"generation": before.token})
        if response.kind != Kind.ACK:
            raise HarnessFailure("idle probe was not acknowledged")
        metadata = response.decoded_metadata()
        if metadata.get("generation") != before.token or int(metadata.get("pid", -1)) != before.pid:
            raise HarnessFailure("idle probe crossed worker generation")
        if self.generation != before:
            raise HarnessFailure("idle worker generation changed during probe")
        return before

    async def prepare(self, *, timeout: float = 60.0) -> dict[str, Any]:
        return await self.prepare_for_trial(timeout=timeout)

    async def prepare_for_trial(
        self,
        *,
        timeout: float = 60.0,
        trial_id: str | None = None,
        fake_prepare_ms: int | None = None,
        stage: str = "normal",
        hold_after_started_ms: int | None = None,
    ) -> dict[str, Any]:
        request_id, _ = await self.begin_prepare_for_trial(
            timeout=min(timeout, 5.0),
            trial_id=trial_id,
            fake_prepare_ms=fake_prepare_ms,
            stage=stage,
            hold_after_started_ms=hold_after_started_ms,
        )
        return await self.finish_prepare_for_trial(request_id, timeout=timeout)

    async def begin_prepare_for_trial(
        self,
        *,
        timeout: float = 5.0,
        trial_id: str | None = None,
        fake_prepare_ms: int | None = None,
        stage: str = "normal",
        hold_after_started_ms: int | None = None,
    ) -> tuple[int, dict[str, Any]]:
        generation = self.generation
        if generation is None:
            raise HarnessFailure("worker is not launched")
        if stage not in ("normal", "protocol_containment"):
            raise HarnessFailure("invalid PREPARE stage")
        metadata: dict[str, Any] = {
            "generation": generation.token,
            "stage": stage,
        }
        if trial_id is not None:
            metadata["trial_id"] = trial_id
        if fake_prepare_ms is not None:
            metadata["fake_prepare_ms"] = fake_prepare_ms
        if hold_after_started_ms is not None:
            metadata["hold_after_started_ms"] = hold_after_started_ms
        async with self._lock:
            if self._poisoned:
                raise HarnessFailure(f"{self.role} generation is transport-poisoned")
            if self._pending_prepare is not None:
                raise HarnessFailure(f"{self.role} already has a staged PREPARE")
            request_id = await self.send(Kind.PREPARE, metadata)
            self._pending_prepare = (
                request_id,
                generation,
                trial_id or "",
                stage,
            )
            try:
                response = await self.receive(timeout=timeout)
            except BaseException:
                self._poisoned = True
                raise
            if response.request_id != request_id or response.kind == Kind.FAILURE:
                self._pending_prepare = None
                if response.kind == Kind.FAILURE:
                    raise HarnessFailure(
                        f"{self.role} failure: "
                        f"{response.decoded_metadata().get('error', 'unknown')}"
                    )
                raise HarnessFailure(f"{self.role} PREPARE_STARTED id mismatch")
            if response.kind != Kind.PREPARE_STARTED:
                self._poisoned = True
                raise HarnessFailure(f"{self.role} did not report PREPARE_STARTED")
            started = response.decoded_metadata()
            expected_tag = exact_trial_tag(trial_id) if trial_id is not None else 0
            if (
                started.get("generation") != generation.token
                or int(started.get("pid", -1)) != generation.pid
                or started.get("trial_id") != (trial_id or "")
                or int(started.get("trial_tag", -1)) != expected_tag
                or started.get("stage") != stage
            ):
                self._poisoned = True
                raise HarnessFailure("PREPARE_STARTED crossed worker/trial/stage identity")
            return request_id, started

    async def finish_prepare_for_trial(
        self, request_id: int, *, timeout: float = 60.0
    ) -> dict[str, Any]:
        async with self._lock:
            if self._poisoned:
                raise HarnessFailure(f"{self.role} generation is transport-poisoned")
            pending = self._pending_prepare
            if pending is None or pending[0] != request_id:
                raise HarnessFailure(f"{self.role} has no matching staged PREPARE")
            _, generation, trial_id, stage = pending
            try:
                response = await self.receive(timeout=timeout)
            except BaseException:
                self._poisoned = True
                raise
            self._pending_prepare = None
        if response.request_id != request_id:
            self._poisoned = True
            raise HarnessFailure(f"{self.role} MODEL_READY id mismatch")
        if response.kind == Kind.FAILURE:
            raise HarnessFailure(
                f"{self.role} failure: "
                f"{response.decoded_metadata().get('error', 'unknown')}"
            )
        if response.kind != Kind.MODEL_READY:
            self._poisoned = True
            raise HarnessFailure(f"{self.role} did not report model ready")
        metadata = response.decoded_metadata()
        if (
            metadata.get("generation") != generation.token
            or int(metadata.get("pid", -1)) != generation.pid
            or metadata.get("trial_id") != trial_id
            or int(metadata.get("trial_tag", -1))
            != (exact_trial_tag(trial_id) if trial_id else 0)
            or metadata.get("stage") != stage
        ):
            self._poisoned = True
            raise HarnessFailure("model-ready marker crossed worker generation")
        return metadata

    async def mark_process_exit(
        self,
        *,
        operation: str,
        trial_id: str,
        trial_tag: int,
        speculative_generation: ExactProcessGeneration,
        timeout: float = 1.0,
    ) -> dict[str, Any]:
        if self.role != "foreground":
            raise HarnessFailure("only foreground may own the process-exit observer")
        if operation not in ("arm_process_exit", "await_process_exit"):
            raise HarnessFailure("invalid process-exit marker operation")
        response = await self.request(
            Kind.TRACE_MARKER,
            {
                "operation": operation,
                "trial_id": trial_id,
                "trial_tag": trial_tag,
                "speculative_pid": speculative_generation.pid,
                "speculative_generation": speculative_generation.token,
            },
            timeout=timeout,
        )
        if response.kind != Kind.ACK:
            raise HarnessFailure("foreground did not acknowledge process-exit marker")
        metadata = response.decoded_metadata()
        expected_observed = operation == "await_process_exit"
        if (
            metadata.get("operation") != operation
            or metadata.get("trial_id") != trial_id
            or int(metadata.get("trial_tag", -1)) != trial_tag
            or int(metadata.get("speculative_pid", -1)) != speculative_generation.pid
            or metadata.get("speculative_generation") != speculative_generation.token
            or int(metadata.get("observer_pid", -1)) != self.pid
            or bool(metadata.get("exit_observed")) != expected_observed
        ):
            raise HarnessFailure("process-exit marker ACK crossed lifecycle identity")
        return metadata

    def resource_snapshot(self) -> ProcessResourceSnapshot:
        """Live child resources without asking the worker to self-report."""

        pid = self.pid
        if platform.system() == "Darwin":
            library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            proc_pidinfo = library.proc_pidinfo
            proc_pidinfo.argtypes = [
                ctypes.c_int,
                ctypes.c_int,
                ctypes.c_uint64,
                ctypes.c_void_p,
                ctypes.c_int,
            ]
            proc_pidinfo.restype = ctypes.c_int
            # PROC_PIDLISTFDS. Each proc_fdinfo is int32 fd + uint32 type.
            fd_bytes = proc_pidinfo(pid, 1, 0, None, 0)
            if fd_bytes <= 0:
                error_number = ctypes.get_errno()
                raise HarnessFailure(
                    f"proc_pidinfo fd query failed for live {pid}: errno={error_number}"
                )
            descriptor_count = fd_bytes // 8

            # `proc_pid_rusage` writes the entire revisioned structure. Use an
            # oversized zeroed buffer rather than a short prefix structure;
            # the latter would let libproc overwrite Python-owned memory.
            usage = ctypes.create_string_buffer(1_024)
            proc_pid_rusage = library.proc_pid_rusage
            proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
            proc_pid_rusage.restype = ctypes.c_int
            if proc_pid_rusage(pid, 2, ctypes.byref(usage)) != 0:
                raise HarnessFailure(f"proc_pid_rusage failed for {pid}")
            # rusage_info_v2: UUID[16], seven UInt64 fields, then
            # `ri_phys_footprint` at byte offset 72.
            phys_footprint = struct.unpack_from("=Q", usage.raw, 72)[0]
            return ProcessResourceSnapshot(
                pid=pid,
                resident_bytes=int(phys_footprint),
                descriptor_count=descriptor_count,
            )

        descriptor_path = Path(f"/proc/{pid}/fd")
        descriptor_count = len(list(descriptor_path.iterdir())) if descriptor_path.exists() else 0
        resident_bytes = 0
        statm_path = Path(f"/proc/{pid}/statm")
        if statm_path.exists():
            fields = statm_path.read_text().split()
            if len(fields) >= 2:
                resident_bytes = int(fields[1]) * os.sysconf("SC_PAGE_SIZE")
        return ProcessResourceSnapshot(pid, resident_bytes, descriptor_count)


class BoundedResourceSampler:
    """High-rate exact-PID sampler with bounded in-memory series ownership."""

    MAXIMUM_SAMPLES = 120_000

    def __init__(self, *, interval_seconds: float = 0.010, limit_bytes: int) -> None:
        if not 0.005 <= interval_seconds <= 0.010:
            raise ValueError("resource interval must be 5-10 ms")
        self.interval_seconds = interval_seconds
        self.limit_bytes = limit_bytes
        self._workers: dict[str, WorkerProcess] = {}
        self._samples: list[ResourceSeriesSample] = []
        self._task: asyncio.Task[None] | None = None
        self._failure: BaseException | None = None

    @property
    def samples(self) -> tuple[ResourceSeriesSample, ...]:
        return tuple(self._samples)

    @property
    def peak_combined_resident_bytes(self) -> int:
        return max((sample.combined_resident_bytes for sample in self._samples), default=0)

    def track(self, role: str, worker: WorkerProcess) -> None:
        if worker.process is None or worker.generation is None:
            raise HarnessFailure(f"cannot track unlaunched {role}")
        if role in self._workers:
            raise HarnessFailure(f"resource role {role} is already tracked")
        self._workers[role] = worker

    def retire(self, role: str, worker: WorkerProcess) -> None:
        current = self._workers.get(role)
        if current is not worker:
            raise HarnessFailure(f"resource role {role} generation mismatch on retire")
        del self._workers[role]

    def retire_if_tracked(self, role: str, worker: WorkerProcess) -> bool:
        if self._workers.get(role) is not worker:
            return False
        del self._workers[role]
        return True

    async def start(self) -> None:
        if self._task is not None:
            raise HarnessFailure("resource sampler already started")
        self._task = asyncio.create_task(self._run())
        self.checkpoint("sampler_started")

    async def stop(self) -> None:
        task = self._task
        if task is None:
            return
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        self._task = None
        self.raise_if_failed()

    def checkpoint(self, label: str) -> ResourceSeriesSample:
        self.raise_if_failed()
        sample = self._sample(label)
        self._samples.append(sample)
        if len(self._samples) > self.MAXIMUM_SAMPLES:
            raise HarnessFailure("resource series exceeded bounded sample count")
        if sample.combined_resident_bytes >= self.limit_bytes:
            raise HarnessFailure(
                f"combined physical footprint reached {sample.combined_resident_bytes} bytes"
            )
        return sample

    def raise_if_failed(self) -> None:
        if self._failure is not None:
            raise HarnessFailure(f"resource sampler failed closed: {self._failure}")

    def write_jsonl(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8") as stream:
            for sample in self._samples:
                stream.write(
                    json.dumps(
                        {
                            "monotonic_ns": sample.monotonic_ns,
                            "label": sample.label,
                            "combined_resident_bytes": sample.combined_resident_bytes,
                            "processes": [dataclasses.asdict(item) for item in sample.processes],
                        },
                        sort_keys=True,
                        separators=(",", ":"),
                    )
                    + "\n"
                )

    async def _run(self) -> None:
        try:
            while True:
                await asyncio.sleep(self.interval_seconds)
                self.checkpoint("periodic")
        except asyncio.CancelledError:
            raise
        except BaseException as error:
            self._failure = error

    def _sample(self, label: str) -> ResourceSeriesSample:
        snapshots: list[ProcessResourceSnapshot] = []
        for role, worker in sorted(self._workers.items()):
            process = worker.process
            generation = worker.generation
            if process is None or generation is None or process.returncode is not None:
                raise HarnessFailure(f"tracked {role} exited before explicit retirement")
            snapshot = worker.resource_snapshot()
            if snapshot.pid != generation.pid:
                raise HarnessFailure(f"resource sample crossed {role} PID generation")
            snapshots.append(snapshot)
        return ResourceSeriesSample(
            monotonic_ns=time.monotonic_ns(),
            label=label,
            processes=tuple(snapshots),
        )


class DualProcessTrialRunner:
    def __init__(
        self,
        *,
        foreground: WorkerProcess,
        speculative_command: Sequence[str],
        expected_identity: ExecutionIdentity,
        speculative_environment: Mapping[str, str] | None = None,
    ) -> None:
        self.foreground = foreground
        self.speculative_command = tuple(speculative_command)
        self.expected_identity = expected_identity
        self.speculative_environment = dict(speculative_environment or {})

    async def run_baseline(
        self,
        *,
        pcm: bytes,
        trial_id: str,
        capture_storage_id: str,
    ) -> TrialObservation:
        started = time.perf_counter_ns()
        response = await self.foreground.request(
            Kind.TRANSCRIBE,
            {
                "trial_id": trial_id,
                "capture_storage_id": capture_storage_id,
                "speculative_generation": None,
                "cache_count": 0,
            },
            pcm,
        )
        ended = time.perf_counter_ns()
        metadata = response.decoded_metadata()
        return TrialObservation(
            arm="baseline",
            stop_offset_ms=0,
            stop_to_result_ns=ended - started,
            kill_to_reap_ns=None,
            speculative_pid=None,
            completed_cache_count=0,
            adopted_cache_count=int(metadata["adopted_cache_count"]),
            ordinary_final_invocations=int(metadata["ordinary_final_invocations"]),
            result=AuditedResult.from_dict(metadata["result"]),
            foreground_request_monotonic_ns=started,
        )

    async def run_stop_during_prepare(
        self,
        *,
        pcm: bytes,
        trial_id: str,
        capture_storage_id: str,
        stop_after_ms: int,
        fake_prepare_ms: int | None = None,
    ) -> PrepareInterruptionObservation:
        if stop_after_ms < 0:
            raise HarnessFailure("negative prepare-stop delay")
        speculative = WorkerProcess(
            self.speculative_command,
            role="speculative",
            expected_identity=self.expected_identity,
            environment=self.speculative_environment,
        )
        await speculative.launch()
        generation = speculative.generation
        if generation is None:
            raise HarnessFailure("replacement S generation disappeared after launch")
        await self.foreground.mark_process_exit(
            operation="arm_process_exit",
            trial_id=trial_id,
            trial_tag=exact_trial_tag(trial_id),
            speculative_generation=generation,
        )
        _, prepare_started = await speculative.begin_prepare_for_trial(
            trial_id=trial_id,
            fake_prepare_ms=fake_prepare_ms,
        )
        if int(prepare_started["prepare_started_monotonic_ns"]) <= 0:
            raise HarnessFailure("replacement PREPARE_STARTED timestamp is invalid")
        try:
            await asyncio.sleep(stop_after_ms / 1_000)
            stop_started = time.perf_counter_ns()
            kill_to_reap_ns = await speculative.kill_and_reap(timeout=1.0)
            reap = speculative.last_reap_markers
            if reap is None or reap.sigkill_monotonic_ns is None:
                raise HarnessFailure("replacement PREPARE was not killed as exact live S")
            await self.foreground.mark_process_exit(
                operation="await_process_exit",
                trial_id=trial_id,
                trial_tag=exact_trial_tag(trial_id),
                speculative_generation=generation,
            )
            foreground_request_ns = time.monotonic_ns()
            if foreground_request_ns < reap.waitpid_monotonic_ns:
                raise HarnessFailure("N+1 foreground request preceded replacement waitpid")
            response = await self.foreground.request(
                Kind.TRANSCRIBE,
                {
                    "trial_id": trial_id,
                    "capture_storage_id": capture_storage_id,
                    "speculative_generation": None,
                    "cache_count": 0,
                },
                pcm,
                timeout=300,
            )
            ended = time.perf_counter_ns()
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
                foreground_request_monotonic_ns=foreground_request_ns,
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
                await speculative.kill_and_reap(allow_already_exited=True)
            raise

    async def run_dual(
        self,
        *,
        pcm: bytes,
        trial_id: str,
        capture_storage_id: str,
        stop_offset_ms: int,
        speculation: Mapping[str, Any],
        event_timeout: float = 2.0,
    ) -> TrialObservation:
        speculative = WorkerProcess(
            self.speculative_command,
            role="speculative",
            expected_identity=self.expected_identity,
            environment=self.speculative_environment,
        )
        await speculative.launch()
        speculative_pid = speculative.pid
        generation = speculative.generation
        assert generation is not None
        await self.foreground.mark_process_exit(
            operation="arm_process_exit",
            trial_id=trial_id,
            trial_tag=exact_trial_tag(trial_id),
            speculative_generation=generation,
        )
        completed: list[SerializedClosedWindowCache] = []
        prediction_started_ns: int | None = None
        try:
            request_id = await speculative.send(
                Kind.SPECULATE,
                {
                    "trial_id": trial_id,
                    "capture_storage_id": capture_storage_id,
                    "speculative_generation": generation.token,
                    **dict(speculation),
                },
                pcm,
            )
            while True:
                frame = await speculative.receive(timeout=event_timeout)
                if frame.request_id != request_id:
                    raise HarnessFailure("speculative event request id mismatch")
                if frame.kind == Kind.CACHE_RECORD:
                    try:
                        completed.append(
                            SerializedClosedWindowCache.from_parts(
                                frame.decoded_metadata(), frame.payload
                            )
                        )
                    except (ValueError, KeyError):
                        # A corrupt speculative result is untrusted input, not
                        # a user-visible ASR failure. Discard all cache records
                        # from this generation and continue toward ordinary F.
                        completed = []
                    continue
                if frame.kind == Kind.PREDICTION_STARTED:
                    prediction_started_ns = int(
                        frame.decoded_metadata()["monotonic_ns"]
                    )
                    break
                if frame.kind == Kind.FAILURE:
                    raise HarnessFailure(
                        f"speculative worker failed: {frame.decoded_metadata()}"
                    )
                raise HarnessFailure(f"unexpected speculative event {frame.kind.name}")

            await asyncio.sleep(stop_offset_ms / 1_000)
            stop_started = time.perf_counter_ns()
            kill_to_reap_ns = await speculative.kill_and_reap()
        except HarnessFailure:
            # A dead/stalled/malformed speculative child is an expected fault
            # lane. Exact reap is mandatory; the foreground result remains the
            # ordinary whole-PCM path and is invoked exactly once below.
            completed = []
            stop_started = time.perf_counter_ns()
            if speculative.process is not None:
                kill_to_reap_ns = await speculative.kill_and_reap(
                    allow_already_exited=True
                )
            else:
                kill_to_reap_ns = 0
        except BaseException:
            if speculative.process is not None:
                await speculative.kill_and_reap()
            raise

        reap = speculative.last_reap_markers
        if reap is not None:
            await self.foreground.mark_process_exit(
                operation="await_process_exit",
                trial_id=trial_id,
                trial_tag=exact_trial_tag(trial_id),
                speculative_generation=generation,
            )

        for record in completed:
            response = await self.foreground.request(
                Kind.CACHE_RECORD,
                record.metadata_dict(),
                record.exact_input_pcm,
            )
            if response.kind != Kind.ACK:
                raise HarnessFailure("foreground did not acknowledge cache record")

        foreground_request_ns = time.monotonic_ns()
        if reap is not None and foreground_request_ns < reap.waitpid_monotonic_ns:
            raise HarnessFailure("foreground request started before exact speculative waitpid")
        response = await self.foreground.request(
            Kind.TRANSCRIBE,
            {
                "trial_id": trial_id,
                "capture_storage_id": capture_storage_id,
                "speculative_generation": generation.token,
                "cache_count": len(completed),
                "planned_descriptors": speculation.get("planned_descriptors", []),
            },
            pcm,
        )
        ended = time.perf_counter_ns()
        metadata = response.decoded_metadata()
        return TrialObservation(
            arm="dual",
            stop_offset_ms=stop_offset_ms,
            stop_to_result_ns=ended - stop_started,
            kill_to_reap_ns=kill_to_reap_ns,
            speculative_pid=speculative_pid,
            completed_cache_count=len(completed),
            adopted_cache_count=int(metadata["adopted_cache_count"]),
            ordinary_final_invocations=int(metadata["ordinary_final_invocations"]),
            result=AuditedResult.from_dict(metadata["result"]),
            prediction_started_monotonic_ns=prediction_started_ns,
            sigkill_monotonic_ns=reap.sigkill_monotonic_ns if reap else None,
            waitpid_monotonic_ns=reap.waitpid_monotonic_ns if reap else None,
            foreground_request_monotonic_ns=foreground_request_ns,
        )


def symmetric_arm_order(offsets: Sequence[int], n_per_arm: int) -> tuple[tuple[str, int], ...]:
    """Deterministic AB/BA balance at every boundary, never all-A then all-B."""

    if n_per_arm <= 0:
        raise ValueError("n_per_arm must be positive")
    order: list[tuple[str, int]] = []
    for offset in offsets:
        for pair in range(n_per_arm):
            arms = ("baseline", "dual") if pair % 2 == 0 else ("dual", "baseline")
            order.extend((arm, offset) for arm in arms)
    return tuple(order)
