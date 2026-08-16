from __future__ import annotations

import hashlib
import json
import os
import signal
import struct
import sys
import time
from typing import Any

from .schema import (
    AuditedResult,
    CacheImportError,
    CacheImporter,
    ClosedWindowDescriptor,
    ExecutionIdentity,
    PrimaryTokenAudit,
    RawTokenWindow,
    SerializedClosedWindowCache,
    canonical_json_bytes,
)
from .wire import Frame, Kind, WireError, read_sync, write_sync


def _identity() -> ExecutionIdentity:
    raw = os.environ.get("DCHF_IDENTITY_JSON")
    if not raw:
        raise RuntimeError("DCHF_IDENTITY_JSON is required")
    value = json.loads(raw)
    if os.environ.get("DCHF_WRONG_HANDSHAKE") == "1":
        value["execution"]["ml_compute_units"] = "cpuOnly"
    return ExecutionIdentity.from_dict(value)


def _mutated_identity(identity: ExecutionIdentity, fault: str) -> ExecutionIdentity:
    value = identity.to_dict()
    if fault == "identity_compute_units":
        value["execution"]["ml_compute_units"] = "cpuOnly"
    elif fault == "identity_os_build":
        value["execution"]["os_build"] = "DIFFERENT"
    elif fault == "identity_coreml_build":
        value["execution"]["coreml_bundle_build"] = "DIFFERENT"
    elif fault == "identity_coreml_binary":
        value["execution"]["coreml_binary_sha256"] = "f" * 64
    elif fault == "identity_coreml_kind":
        value["execution"]["coreml_binary_identity_kind"] = "different"
    elif fault == "identity_model":
        value["model_files"][0]["sha256"] = "e" * 64
    elif fault == "identity_config":
        value["configuration_json_b64"] = __import__("base64").b64encode(
            canonical_json_bytes({"parallel_chunk_concurrency": 3})
        ).decode("ascii")
    elif fault == "identity_language":
        value["language_hint"] = "en" if value.get("language_hint") != "en" else "ru"
    elif fault == "identity_vocabulary":
        value["vocabulary_json_b64"] = __import__("base64").b64encode(
            canonical_json_bytes({"revision": 999, "terms": []})
        ).decode("ascii")
    return ExecutionIdentity.from_dict(value)


def _audited_result(pcm: bytes) -> AuditedResult:
    digest = hashlib.sha256(pcm).hexdigest()
    tokens = (
        PrimaryTokenAudit(
            token="fixture",
            token_id=7,
            start_time_bits=0,
            end_time_bits=0x3FF0_0000_0000_0000,
            confidence_bits=0x3F00_0000,
        ),
        PrimaryTokenAudit(
            token=f" {digest[:12]}",
            token_id=11,
            start_time_bits=0x3FF0_0000_0000_0000,
            end_time_bits=0x4000_0000_0000_0000,
            confidence_bits=0x3F40_0000,
        ),
    )
    return AuditedResult(
        transcript=f"fixture {digest[:12]}",
        primary_tokens=tokens,
        word_records_json=canonical_json_bytes(
            [
                {
                    "end_time_bits": 0x3F80_0000,
                    "start_time_bits": 0,
                    "word": "fixture",
                },
                {
                    "end_time_bits": 0x4000_0000,
                    "start_time_bits": 0x3F80_0000,
                    "word": digest[:12],
                },
            ]
        ),
        vocabulary_outcome=os.environ.get("DCHF_VOCAB_OUTCOME", "no_candidate"),
        candidate_regions_json=canonical_json_bytes([]),
        audio_duration_bits=int.from_bytes(
            struct.pack(">d", len(pcm) / 4 / 16_000), "big"
        ),
    )


class FakeWorker:
    def __init__(self) -> None:
        self.role = os.environ.get("DCHF_ROLE", "")
        self.identity = _identity()
        self.generation = ""
        self.pending_cache_parts: list[tuple[dict[str, Any], bytes]] = []
        self.armed_process_exits: set[tuple[int, int, str]] = set()

    def run(self) -> int:
        while True:
            frame = read_sync(sys.stdin.buffer)
            if frame is None:
                return 0
            try:
                should_stop = self.handle(frame)
            except BaseException as error:
                write_sync(
                    sys.stdout.buffer,
                    Frame.json(
                        Kind.FAILURE,
                        frame.request_id,
                        {"error": f"{type(error).__name__}: {error}"},
                    ),
                )
                if isinstance(error, (KeyboardInterrupt, SystemExit)):
                    raise
                continue
            if should_stop:
                return 0

    def handle(self, frame: Frame) -> bool:
        metadata = frame.decoded_metadata()
        if frame.kind == Kind.HELLO:
            if metadata["role"] != self.role:
                raise RuntimeError("role mismatch")
            self.generation = str(metadata["generation"])
            write_sync(
                sys.stdout.buffer,
                Frame.json(
                    Kind.HELLO_ACK,
                    frame.request_id,
                    {"identity": self.identity.to_dict()},
                ),
            )
            return False

        if frame.kind == Kind.SHUTDOWN:
            write_sync(sys.stdout.buffer, Frame.json(Kind.ACK, frame.request_id, {}))
            return True

        if frame.kind == Kind.PING:
            if metadata.get("generation") != self.generation:
                raise RuntimeError("idle probe generation mismatch")
            write_sync(
                sys.stdout.buffer,
                Frame.json(
                    Kind.ACK,
                    frame.request_id,
                    {"generation": self.generation, "pid": os.getpid()},
                ),
            )
            return False

        if frame.kind == Kind.PREPARE:
            started = time.monotonic_ns()
            trial_id = str(metadata.get("trial_id", ""))
            trial_tag = (
                int.from_bytes(hashlib.sha256(trial_id.encode()).digest()[:8], "big")
                if trial_id
                else 0
            )
            stage = str(metadata.get("stage", "normal"))
            if stage not in ("normal", "protocol_containment"):
                raise RuntimeError("invalid fake PREPARE stage")
            write_sync(
                sys.stdout.buffer,
                Frame.json(
                    Kind.PREPARE_STARTED,
                    frame.request_id,
                    {
                        "generation": self.generation,
                        "pid": os.getpid(),
                        "trial_id": trial_id,
                        "trial_tag": trial_tag,
                        "stage": stage,
                        "prepare_started_monotonic_ns": started,
                    },
                ),
            )
            delay_ms = int(metadata.get("fake_prepare_ms", 0))
            delay_ms = max(delay_ms, int(metadata.get("hold_after_started_ms", 0)))
            if delay_ms:
                time.sleep(delay_ms / 1_000)
            write_sync(
                sys.stdout.buffer,
                Frame.json(
                    Kind.MODEL_READY,
                    frame.request_id,
                    {
                        "generation": self.generation,
                        "pid": os.getpid(),
                        "trial_id": trial_id,
                        "trial_tag": trial_tag,
                        "stage": stage,
                        "prepare_started_monotonic_ns": started,
                        "model_ready_monotonic_ns": time.monotonic_ns(),
                    },
                ),
            )
            return False

        if self.role == "foreground" and frame.kind == Kind.TRACE_MARKER:
            operation = str(metadata.get("operation", ""))
            speculative_pid = int(metadata.get("speculative_pid", -1))
            trial_tag = int(metadata.get("trial_tag", -1))
            speculative_generation = str(metadata.get("speculative_generation", ""))
            expected_tag = int.from_bytes(
                hashlib.sha256(str(metadata.get("trial_id", "")).encode()).digest()[:8],
                "big",
            )
            if trial_tag != expected_tag or speculative_pid <= 1 or not speculative_generation:
                raise RuntimeError("invalid process-exit marker identity")
            key = (speculative_pid, trial_tag, speculative_generation)
            if operation == "arm_process_exit":
                os.kill(speculative_pid, 0)
                if key in self.armed_process_exits:
                    raise RuntimeError("duplicate process-exit observer")
                self.armed_process_exits.add(key)
                observed = False
            elif operation == "await_process_exit":
                if key not in self.armed_process_exits:
                    raise RuntimeError("process-exit observer was not armed")
                try:
                    os.kill(speculative_pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise RuntimeError("speculative process is still live")
                self.armed_process_exits.remove(key)
                observed = True
            else:
                raise RuntimeError("unknown process-exit marker operation")
            write_sync(
                sys.stdout.buffer,
                Frame.json(
                    Kind.ACK,
                    frame.request_id,
                    {
                        "operation": operation,
                        "trial_id": metadata["trial_id"],
                        "trial_tag": trial_tag,
                        "speculative_pid": speculative_pid,
                        "speculative_generation": speculative_generation,
                        "observer_pid": os.getpid(),
                        "exit_observed": observed,
                    },
                ),
            )
            return False

        if self.role == "speculative" and frame.kind == Kind.SPECULATE:
            self._speculate(frame, metadata)
            return False

        if self.role == "foreground" and frame.kind == Kind.CACHE_RECORD:
            # ACK means only bounded ownership transfer. Semantic adoption is
            # deferred until the authoritative final PCM and plan arrive.
            self.pending_cache_parts.append((metadata, frame.payload))
            write_sync(sys.stdout.buffer, Frame.json(Kind.ACK, frame.request_id, {}))
            return False

        if self.role == "foreground" and frame.kind == Kind.TRANSCRIBE:
            self._transcribe(frame, metadata)
            return False

        raise RuntimeError(f"unsupported {self.role} message {frame.kind.name}")

    def _speculate(self, frame: Frame, metadata: dict[str, Any]) -> None:
        fault = str(metadata.get("fault", ""))
        if fault == "exit_before_prediction":
            os._exit(72)
        if fault == "stall_before_prediction":
            time.sleep(60)
            return
        if fault == "malformed_frame":
            os.write(sys.stdout.fileno(), b"BAD!")
            os._exit(73)

        descriptors = [
            ClosedWindowDescriptor.from_dict(item)
            for item in metadata.get("completed_descriptors", [])
        ]
        producer_identity = _mutated_identity(self.identity, fault)
        for descriptor in descriptors:
            lower = descriptor.context_start * 4
            upper = descriptor.chunk_end * 4
            exact_input = frame.payload[lower:upper]
            if fault == "cache_pcm_bitflip" and exact_input:
                exact_input = bytes([exact_input[0] ^ 1]) + exact_input[1:]
            generation = str(metadata["speculative_generation"])
            if fault == "wrong_generation":
                generation += "-stale"
            emitted_descriptor = descriptor
            if fault == "descriptor_mismatch":
                emitted_descriptor = dataclass_replace_descriptor(descriptor)
            record = SerializedClosedWindowCache(
                trial_id=str(metadata["trial_id"]),
                capture_storage_id=str(metadata["capture_storage_id"]),
                speculative_generation=generation,
                producer_identity=producer_identity,
                language_raw_value=producer_identity.language_hint,
                descriptor=emitted_descriptor,
                exact_input_pcm=exact_input,
                tokens=(
                    RawTokenWindow(
                        token=descriptor.index + 1,
                        timestamp=descriptor.chunk_start // 1280,
                        confidence_bits=0x3F00_0000,
                        duration=1,
                    ),
                ),
            )
            cache_metadata = record.metadata_dict()
            if fault == "transport_digest":
                cache_metadata["input_sha256"] = "0" * 64
            write_sync(
                sys.stdout.buffer,
                Frame.json(
                    Kind.CACHE_RECORD,
                    frame.request_id,
                    cache_metadata,
                    record.exact_input_pcm,
                ),
            )
            if fault == "duplicate_index":
                write_sync(
                    sys.stdout.buffer,
                    Frame.json(
                        Kind.CACHE_RECORD,
                        frame.request_id,
                        cache_metadata,
                        record.exact_input_pcm,
                    ),
                )

        write_sync(
            sys.stdout.buffer,
            Frame.json(
                Kind.PREDICTION_STARTED,
                frame.request_id,
                {"monotonic_ns": time.monotonic_ns(), "window_index": 1},
            ),
        )
        time.sleep(float(metadata.get("active_ms", 250)) / 1_000)
        write_sync(
            sys.stdout.buffer,
            Frame.json(
                Kind.PREDICTION_COMPLETED,
                frame.request_id,
                {"monotonic_ns": time.monotonic_ns(), "window_index": 1},
            ),
        )
        write_sync(sys.stdout.buffer, Frame.json(Kind.ACK, frame.request_id, {}))

    def _transcribe(self, frame: Frame, metadata: dict[str, Any]) -> None:
        pending, self.pending_cache_parts = self.pending_cache_parts, []
        records: list[SerializedClosedWindowCache] = []
        rejection: str | None = None
        try:
            records = [
                SerializedClosedWindowCache.from_parts(cache_metadata, payload)
                for cache_metadata, payload in pending
            ]
            if len(records) != int(metadata["cache_count"]):
                raise CacheImportError("cache_count_mismatch")
            planned = {
                descriptor.index: descriptor
                for descriptor in (
                    ClosedWindowDescriptor.from_dict(item)
                    for item in metadata.get("planned_descriptors", [])
                )
            }
            if records:
                CacheImporter.validate(
                    records,
                    expected_identity=self.identity,
                    trial_id=str(metadata["trial_id"]),
                    capture_storage_id=str(metadata["capture_storage_id"]),
                    speculative_generation=str(metadata["speculative_generation"]),
                    authoritative_pcm=frame.payload,
                    planned_descriptors=planned,
                )
        except (CacheImportError, ValueError, KeyError) as error:
            records = []
            rejection = error.code if isinstance(error, CacheImportError) else type(error).__name__

        adopted_count = len(records)
        ordinary_invocations = 0 if adopted_count else 1
        result = _audited_result(frame.payload)
        write_sync(
            sys.stdout.buffer,
            Frame.json(
                Kind.RESULT,
                frame.request_id,
                {
                    "adopted_cache_count": adopted_count,
                    "ordinary_final_invocations": ordinary_invocations,
                    "cache_rejection": rejection,
                    "result": result.to_dict(),
                },
            ),
        )


def dataclass_replace_descriptor(descriptor: ClosedWindowDescriptor) -> ClosedWindowDescriptor:
    # Shift only the stable watermark. The record remains internally valid but
    # no longer equals the foreground planner's independently derived plan.
    return ClosedWindowDescriptor(
        **{
            **descriptor.to_dict(),
            "earliest_safe_prefix_sample_count": descriptor.earliest_safe_prefix_sample_count + 1,
        }
    )


def main() -> int:
    try:
        return FakeWorker().run()
    except (EOFError, WireError, BrokenPipeError):
        return 74


if __name__ == "__main__":
    raise SystemExit(main())
