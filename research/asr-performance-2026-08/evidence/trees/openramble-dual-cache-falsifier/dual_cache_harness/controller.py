from __future__ import annotations

import asyncio
import ctypes
import dataclasses
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
        response = await self.request(
            Kind.HELLO,
            {
                "role": self.role,
                "generation": self.generation.token,
                "expected_identity": self.expected_identity.to_dict(),
            },
        )
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
            request_id = await self.send(kind, metadata, payload)
            frame = await self.receive(timeout=timeout)
            if frame.request_id != request_id:
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
        if process.returncode is None:
            process.kill()
        try:
            return_code = await asyncio.wait_for(process.wait(), timeout=timeout)
        except asyncio.TimeoutError as error:
            raise HarnessFailure(
                f"exact worker generation {generation.token}/{generation.pid} did not reap"
            ) from error
        finally:
            if process.stdin is not None:
                process.stdin.close()
            self.process = None
            self.generation = None
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
            if fd_bytes < 0:
                raise HarnessFailure(f"proc_pidinfo fd query failed for {pid}")
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
        )

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
        completed: list[SerializedClosedWindowCache] = []
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

        for record in completed:
            response = await self.foreground.request(
                Kind.CACHE_RECORD,
                record.metadata_dict(),
                record.exact_input_pcm,
            )
            if response.kind != Kind.ACK:
                raise HarnessFailure("foreground did not acknowledge cache record")

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
