#!/usr/bin/env python3
"""Pure reference state machine for a lossless canonical endpoint proposal.

The module never performs VAD or ASR inference. Callers supply pinned VAD
probabilities so capture/key/fallback semantics can be tested on CPU alone.
"""

from __future__ import annotations

import hashlib
import json
import math
import struct
from dataclasses import dataclass


SAMPLE_RATE = 16_000
VAD_CHUNK_SAMPLES = 4_096
VAD_CONTEXT_SAMPLES = 64
ENTRY_THRESHOLD = 0.85
EXIT_THRESHOLD = 0.70
MIN_SILENCE_CHUNKS = 2
GUARD_SAMPLES = 4_096
CONTRACT_VERSION = "canonical-endpoint-silero-v6.2.1-256ms-v1"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def config_digest(parameters: dict[str, object]) -> str:
    encoded = json.dumps(parameters, sort_keys=True, separators=(",", ":")).encode()
    return sha256(encoded)


@dataclass(frozen=True)
class CandidateKey:
    session_id: str
    ingress_generation: int
    canonical_pcm_sha256: str
    canonical_sample_count: int
    contract_version: str
    model_revision: str
    product_config_sha256: str
    vocabulary_snapshot_sha256: str
    language_hint: str | None

    def digest(self) -> str:
        return config_digest(self.__dict__)


@dataclass
class Candidate:
    key: CandidateKey
    cut_sample: int
    launched_at_sample: int
    status: str = "pending"
    invalid_reason: str | None = None


@dataclass(frozen=True)
class StopDecision:
    path: str
    sample_count: int
    pcm_sha256: str
    reason: str


class EndpointMachine:
    """Append-only capture plus deterministic endpoint/candidate policy."""

    def __init__(
        self,
        *,
        session_id: str,
        ingress_generation: int,
        model_revision: str,
        product_config_sha256: str,
        vocabulary_snapshot_sha256: str,
        language_hint: str | None,
    ) -> None:
        self.session_id = session_id
        self.ingress_generation = ingress_generation
        self.model_revision = model_revision
        self.product_config_sha256 = product_config_sha256
        self.vocabulary_snapshot_sha256 = vocabulary_snapshot_sha256
        self.language_hint = language_hint
        self._pcm = bytearray()
        self._triggered = False
        self._silence_start: int | None = None
        self._candidate: Candidate | None = None
        self._invalid = False
        self._stopped = False

    @property
    def sample_count(self) -> int:
        return len(self._pcm) // 4

    @property
    def candidate(self) -> Candidate | None:
        return self._candidate

    @property
    def raw_pcm_sha256(self) -> str:
        return sha256(bytes(self._pcm))

    def _validate_probability(self, probability: float) -> None:
        if not math.isfinite(probability) or not 0.0 <= probability <= 1.0:
            self._invalid = True
            self._invalidate_candidate("invalid_vad_probability")
            raise ValueError("probability must be finite and in [0,1]")

    def _invalidate_candidate(self, reason: str) -> None:
        if self._candidate is not None and self._candidate.status != "invalid":
            self._candidate.status = "invalid"
            self._candidate.invalid_reason = reason

    def ingest_full_chunk(self, pcm_f32le: bytes, probability: float) -> Candidate | None:
        if self._stopped:
            raise RuntimeError("capture already stopped")
        if len(pcm_f32le) != VAD_CHUNK_SAMPLES * 4:
            self._invalid = True
            self._invalidate_candidate("invalid_chunk_size")
            raise ValueError("full VAD chunk must contain exactly 4096 Float32 samples")
        self._validate_probability(probability)
        chunk_start = self.sample_count
        self._pcm.extend(pcm_f32le)
        processed_end = self.sample_count

        if probability >= ENTRY_THRESHOLD:
            if self._candidate is not None:
                self._invalidate_candidate("resumed_speech")
            self._silence_start = None
            self._triggered = True
            return None

        if probability < EXIT_THRESHOLD and self._triggered:
            if self._silence_start is None:
                self._silence_start = chunk_start
            silence_samples = processed_end - self._silence_start
            if silence_samples >= MIN_SILENCE_CHUNKS * VAD_CHUNK_SAMPLES:
                cut_sample = min(processed_end, self._silence_start + GUARD_SAMPLES)
                canonical_bytes = bytes(self._pcm[: cut_sample * 4])
                key = CandidateKey(
                    session_id=self.session_id,
                    ingress_generation=self.ingress_generation,
                    canonical_pcm_sha256=sha256(canonical_bytes),
                    canonical_sample_count=cut_sample,
                    contract_version=CONTRACT_VERSION,
                    model_revision=self.model_revision,
                    product_config_sha256=self.product_config_sha256,
                    vocabulary_snapshot_sha256=self.vocabulary_snapshot_sha256,
                    language_hint=self.language_hint,
                )
                self._candidate = Candidate(
                    key=key,
                    cut_sample=cut_sample,
                    launched_at_sample=processed_end,
                )
                self._triggered = False
                self._silence_start = None
                return self._candidate
        return None

    def append_unclassified_partial(self, pcm_f32le: bytes) -> None:
        if self._stopped:
            raise RuntimeError("capture already stopped")
        if len(pcm_f32le) % 4 != 0 or len(pcm_f32le) >= VAD_CHUNK_SAMPLES * 4:
            self._invalid = True
            self._invalidate_candidate("invalid_partial_size")
            raise ValueError("partial must be Float32-aligned and shorter than one VAD chunk")
        self._pcm.extend(pcm_f32le)

    def validate_stop_partial(self, probability: float) -> None:
        """Validate only; repeat-last model padding is never appended to ASR PCM."""
        self._validate_probability(probability)
        if self._candidate is None:
            return
        if probability >= EXIT_THRESHOLD:
            self._invalidate_candidate("stop_partial_not_confident_silence")

    def mark_candidate_ready(self, key_digest: str) -> None:
        if self._candidate is None:
            raise RuntimeError("no candidate")
        if key_digest != self._candidate.key.digest():
            self._invalidate_candidate("result_key_mismatch")
            return
        if self._candidate.status != "invalid":
            self._candidate.status = "ready"

    def mark_candidate_failed(self) -> None:
        self._invalidate_candidate("speculative_failure")

    def stop(self) -> StopDecision:
        self._stopped = True
        raw = bytes(self._pcm)
        if self._invalid:
            return StopDecision("ordinary_raw", self.sample_count, sha256(raw), "invalid_state")
        candidate = self._candidate
        if candidate is None:
            return StopDecision("ordinary_raw", self.sample_count, sha256(raw), "no_confirmed_endpoint")
        if candidate.status == "ready":
            canonical = raw[: candidate.cut_sample * 4]
            if sha256(canonical) != candidate.key.canonical_pcm_sha256:
                return StopDecision("ordinary_raw", self.sample_count, sha256(raw), "canonical_key_mismatch")
            return StopDecision(
                "reuse_ready_candidate",
                candidate.cut_sample,
                candidate.key.canonical_pcm_sha256,
                "exact_key_match",
            )
        if candidate.status == "pending":
            return StopDecision(
                "wait_pending_exact_candidate",
                candidate.cut_sample,
                candidate.key.canonical_pcm_sha256,
                "single_worker_candidate_pending",
            )
        return StopDecision("ordinary_raw", self.sample_count, sha256(raw), candidate.invalid_reason or "invalid")


def constant_chunk(value: float) -> bytes:
    return struct.pack("<f", value) * VAD_CHUNK_SAMPLES
