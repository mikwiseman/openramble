from __future__ import annotations

import base64
import dataclasses
import hashlib
import json
import math
import re
from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Sequence


SCHEMA_VERSION = 1
SAMPLE_RATE = 16_000
MAX_MODEL_SAMPLES = 240_000
MAX_FINAL_SAMPLES = 5 * 60 * SAMPLE_RATE
MAX_CACHE_RECORDS = 32
MAX_CACHE_INPUT_BYTES = MAX_MODEL_SAMPLES * 4
MAX_CACHE_TOTAL_BYTES = 24 * 1024 * 1024
MAX_TOKEN_WINDOWS_PER_RECORD = 8_192
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


class CacheImportError(ValueError):
    """A fail-closed cache rejection. The caller must use ordinary ASR."""

    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail


def _require_sha256(value: str, field: str) -> None:
    if not _SHA256.fullmatch(value):
        raise ValueError(f"{field} must be lowercase SHA-256 hex")


def canonical_json_bytes(value: Any) -> bytes:
    """Canonical identity bytes; floats are forbidden in favor of bit patterns."""

    def validate(node: Any, path: str) -> None:
        if node is None or isinstance(node, (bool, str, int)):
            return
        if isinstance(node, float):
            raise ValueError(f"{path}: encode floating-point settings as IEEE bit integers")
        if isinstance(node, list):
            for index, child in enumerate(node):
                validate(child, f"{path}[{index}]")
            return
        if isinstance(node, dict):
            for key, child in node.items():
                if not isinstance(key, str):
                    raise ValueError(f"{path}: identity keys must be strings")
                validate(child, f"{path}.{key}")
            return
        raise ValueError(f"{path}: unsupported identity value {type(node).__name__}")

    validate(value, "identity")
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


@dataclass(frozen=True, order=True)
class ArtifactFileIdentity:
    relative_path: str
    byte_count: int
    sha256: str

    def __post_init__(self) -> None:
        if not self.relative_path or self.relative_path.startswith("/") or ".." in self.relative_path.split("/"):
            raise ValueError("artifact relative_path must be a safe nonempty relative path")
        if self.byte_count < 0:
            raise ValueError("artifact byte_count must be nonnegative")
        _require_sha256(self.sha256, "artifact sha256")

    def to_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "ArtifactFileIdentity":
        return cls(
            relative_path=str(value["relative_path"]),
            byte_count=int(value["byte_count"]),
            sha256=str(value["sha256"]),
        )


@dataclass(frozen=True)
class ModelExecutionIdentity:
    """Everything known to select a Core ML execution/numerics route."""

    ml_compute_units: str
    encoder_placement: str
    hardware_model: str
    architecture: str
    os_version: str
    os_build: str
    coreml_bundle_version: str
    coreml_bundle_build: str
    coreml_binary_sha256: str

    def __post_init__(self) -> None:
        fields = (
            self.ml_compute_units,
            self.encoder_placement,
            self.hardware_model,
            self.architecture,
            self.os_version,
            self.os_build,
            self.coreml_bundle_version,
            self.coreml_bundle_build,
        )
        if any(not value for value in fields):
            raise ValueError("model execution identity fields must be nonempty")
        _require_sha256(self.coreml_binary_sha256, "CoreML binary sha256")

    def to_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "ModelExecutionIdentity":
        return cls(**{field.name: str(value[field.name]) for field in dataclasses.fields(cls)})


@dataclass(frozen=True)
class ExecutionIdentity:
    schema_version: int
    executable_sha256: str
    executable_device: int
    executable_inode: int
    code_revision: str
    model_files: tuple[ArtifactFileIdentity, ...]
    vocabulary_files: tuple[ArtifactFileIdentity, ...]
    configuration_json: bytes
    vocabulary_json: bytes
    language_hint: str | None
    execution: ModelExecutionIdentity

    def __post_init__(self) -> None:
        if self.schema_version != SCHEMA_VERSION:
            raise ValueError("unsupported execution identity schema")
        _require_sha256(self.executable_sha256, "executable sha256")
        if self.executable_device < 0 or self.executable_inode <= 0:
            raise ValueError("executable lineage must contain device and inode")
        if not self.code_revision:
            raise ValueError("code_revision must be nonempty")
        if tuple(sorted(self.model_files)) != self.model_files or len(set(self.model_files)) != len(self.model_files):
            raise ValueError("model file identity must be sorted and unique")
        if tuple(sorted(self.vocabulary_files)) != self.vocabulary_files or len(set(self.vocabulary_files)) != len(self.vocabulary_files):
            raise ValueError("vocabulary file identity must be sorted and unique")
        # Parse and re-canonicalize so two byte spellings cannot compare equal by accident.
        for label, payload in (
            ("configuration_json", self.configuration_json),
            ("vocabulary_json", self.vocabulary_json),
        ):
            try:
                decoded = json.loads(payload)
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise ValueError(f"{label} is not JSON") from error
            if canonical_json_bytes(decoded) != payload:
                raise ValueError(f"{label} is not canonical")

    @classmethod
    def make(
        cls,
        *,
        executable_sha256: str,
        executable_device: int,
        executable_inode: int,
        code_revision: str,
        model_files: Iterable[ArtifactFileIdentity],
        vocabulary_files: Iterable[ArtifactFileIdentity],
        configuration: Any,
        vocabulary: Any,
        language_hint: str | None,
        execution: ModelExecutionIdentity,
    ) -> "ExecutionIdentity":
        return cls(
            schema_version=SCHEMA_VERSION,
            executable_sha256=executable_sha256,
            executable_device=executable_device,
            executable_inode=executable_inode,
            code_revision=code_revision,
            model_files=tuple(sorted(model_files)),
            vocabulary_files=tuple(sorted(vocabulary_files)),
            configuration_json=canonical_json_bytes(configuration),
            vocabulary_json=canonical_json_bytes(vocabulary),
            language_hint=language_hint,
            execution=execution,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "executable_sha256": self.executable_sha256,
            "executable_device": self.executable_device,
            "executable_inode": self.executable_inode,
            "code_revision": self.code_revision,
            "model_files": [item.to_dict() for item in self.model_files],
            "vocabulary_files": [item.to_dict() for item in self.vocabulary_files],
            "configuration_json_b64": base64.b64encode(self.configuration_json).decode("ascii"),
            "vocabulary_json_b64": base64.b64encode(self.vocabulary_json).decode("ascii"),
            "language_hint": self.language_hint,
            "execution": self.execution.to_dict(),
        }

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "ExecutionIdentity":
        return cls(
            schema_version=int(value["schema_version"]),
            executable_sha256=str(value["executable_sha256"]),
            executable_device=int(value["executable_device"]),
            executable_inode=int(value["executable_inode"]),
            code_revision=str(value["code_revision"]),
            model_files=tuple(ArtifactFileIdentity.from_dict(item) for item in value["model_files"]),
            vocabulary_files=tuple(ArtifactFileIdentity.from_dict(item) for item in value["vocabulary_files"]),
            configuration_json=base64.b64decode(value["configuration_json_b64"], validate=True),
            vocabulary_json=base64.b64decode(value["vocabulary_json_b64"], validate=True),
            language_hint=value.get("language_hint"),
            execution=ModelExecutionIdentity.from_dict(value["execution"]),
        )

    @property
    def canonical_sha256(self) -> str:
        return hashlib.sha256(canonical_json_bytes(self.to_dict())).hexdigest()


@dataclass(frozen=True)
class ClosedWindowDescriptor:
    index: int
    chunk_start: int
    context_start: int
    chunk_end: int
    context_samples: int
    chunk_start_offset: int
    emit_tokens_after_frame: int | None
    initial_time_index_override: int | None
    earliest_safe_prefix_sample_count: int
    is_last_chunk: bool = False

    def __post_init__(self) -> None:
        if self.index < 0:
            raise ValueError("negative closed-window index")
        if not (0 <= self.context_start <= self.chunk_start < self.chunk_end):
            raise ValueError("invalid closed-window sample bounds")
        if self.chunk_end - self.context_start > MAX_MODEL_SAMPLES:
            raise ValueError("closed-window input exceeds model limit")
        if self.context_samples < 0 or self.chunk_start_offset < 0:
            raise ValueError("invalid closed-window context")
        if self.earliest_safe_prefix_sample_count <= self.chunk_end:
            raise ValueError("closed-window stability watermark is not beyond its input")
        if self.is_last_chunk:
            raise ValueError("a serialized cache may never represent the final window")

    def to_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "ClosedWindowDescriptor":
        return cls(**{field.name: value[field.name] for field in dataclasses.fields(cls)})


@dataclass(frozen=True)
class RawTokenWindow:
    token: int
    timestamp: int
    confidence_bits: int
    duration: int

    def __post_init__(self) -> None:
        if self.token < 0 or self.timestamp < 0 or self.duration < 0:
            raise ValueError("negative token-window field")
        if not 0 <= self.confidence_bits <= 0xFFFF_FFFF:
            raise ValueError("confidence_bits is not Float32 bits")

    def to_dict(self) -> dict[str, int]:
        return dataclasses.asdict(self)

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "RawTokenWindow":
        return cls(**{field.name: int(value[field.name]) for field in dataclasses.fields(cls)})


@dataclass(frozen=True)
class SerializedClosedWindowCache:
    trial_id: str
    capture_storage_id: str
    speculative_generation: str
    producer_identity: ExecutionIdentity
    descriptor: ClosedWindowDescriptor
    exact_input_pcm: bytes
    tokens: tuple[RawTokenWindow, ...]

    def __post_init__(self) -> None:
        if not self.trial_id or not self.capture_storage_id or not self.speculative_generation:
            raise ValueError("cache ownership fields must be nonempty")
        expected_bytes = (self.descriptor.chunk_end - self.descriptor.context_start) * 4
        if len(self.exact_input_pcm) != expected_bytes or len(self.exact_input_pcm) > MAX_CACHE_INPUT_BYTES:
            raise ValueError("cache input byte count does not match descriptor")
        if len(self.tokens) > MAX_TOKEN_WINDOWS_PER_RECORD:
            raise ValueError("cache token count exceeds bound")

    def metadata_dict(self) -> dict[str, Any]:
        return {
            "trial_id": self.trial_id,
            "capture_storage_id": self.capture_storage_id,
            "speculative_generation": self.speculative_generation,
            "producer_identity": self.producer_identity.to_dict(),
            "descriptor": self.descriptor.to_dict(),
            "tokens": [token.to_dict() for token in self.tokens],
            # Diagnostic integrity only. Import still compares every input byte.
            "input_sha256": hashlib.sha256(self.exact_input_pcm).hexdigest(),
        }

    @classmethod
    def from_parts(
        cls,
        metadata: Mapping[str, Any],
        payload: bytes,
    ) -> "SerializedClosedWindowCache":
        claimed = str(metadata["input_sha256"])
        _require_sha256(claimed, "cache input sha256")
        if hashlib.sha256(payload).hexdigest() != claimed:
            raise CacheImportError("transport_integrity_mismatch")
        return cls(
            trial_id=str(metadata["trial_id"]),
            capture_storage_id=str(metadata["capture_storage_id"]),
            speculative_generation=str(metadata["speculative_generation"]),
            producer_identity=ExecutionIdentity.from_dict(metadata["producer_identity"]),
            descriptor=ClosedWindowDescriptor.from_dict(metadata["descriptor"]),
            exact_input_pcm=payload,
            tokens=tuple(RawTokenWindow.from_dict(item) for item in metadata["tokens"]),
        )


class CacheImporter:
    """Foreground-side exact validation before replacing the local owner."""

    @staticmethod
    def validate(
        records: Sequence[SerializedClosedWindowCache],
        *,
        expected_identity: ExecutionIdentity,
        trial_id: str,
        capture_storage_id: str,
        speculative_generation: str,
        authoritative_pcm: bytes,
        planned_descriptors: Mapping[int, ClosedWindowDescriptor],
    ) -> tuple[SerializedClosedWindowCache, ...]:
        if len(authoritative_pcm) % 4 or len(authoritative_pcm) // 4 > MAX_FINAL_SAMPLES:
            raise CacheImportError("invalid_authoritative_pcm")
        if len(records) > MAX_CACHE_RECORDS:
            raise CacheImportError("too_many_cache_records")
        if sum(len(record.exact_input_pcm) for record in records) > MAX_CACHE_TOTAL_BYTES:
            raise CacheImportError("cache_total_too_large")

        seen: set[int] = set()
        accepted: list[SerializedClosedWindowCache] = []
        for record in records:
            if record.trial_id != trial_id or record.capture_storage_id != capture_storage_id:
                raise CacheImportError("session_or_storage_mismatch")
            if record.speculative_generation != speculative_generation:
                raise CacheImportError("speculative_generation_mismatch")
            if record.producer_identity != expected_identity:
                raise CacheImportError("execution_identity_mismatch")
            descriptor = planned_descriptors.get(record.descriptor.index)
            if descriptor is None or descriptor != record.descriptor:
                raise CacheImportError("foreground_plan_mismatch")
            if record.descriptor.index in seen:
                raise CacheImportError("duplicate_window_index")
            seen.add(record.descriptor.index)

            lower = record.descriptor.context_start * 4
            upper = record.descriptor.chunk_end * 4
            if upper > len(authoritative_pcm):
                raise CacheImportError("authoritative_pcm_too_short")
            # This direct equality is the semantic proof. SHA-256 above is only
            # a corruption diagnostic and is never an acceptance substitute.
            if authoritative_pcm[lower:upper] != record.exact_input_pcm:
                raise CacheImportError("exact_input_mismatch")
            accepted.append(record)
        return tuple(sorted(accepted, key=lambda item: item.descriptor.index))


@dataclass(frozen=True)
class AuditedResult:
    transcript: str
    primary_tokens: tuple[RawTokenWindow, ...]
    token_strings: tuple[str, ...]
    word_records_json: bytes
    vocabulary_outcome: str
    candidate_regions_json: bytes

    def __post_init__(self) -> None:
        if len(self.primary_tokens) != len(self.token_strings):
            raise ValueError("audited token arrays are misaligned")
        for label, payload in (
            ("word_records_json", self.word_records_json),
            ("candidate_regions_json", self.candidate_regions_json),
        ):
            decoded = json.loads(payload)
            if canonical_json_bytes(decoded) != payload:
                raise ValueError(f"{label} is not canonical")

    def assert_exact_parity(self, other: "AuditedResult") -> None:
        if self != other:
            raise AssertionError("full transcript/token/timing/vocabulary result differs")

    def to_dict(self, *, include_sensitive_text: bool = True) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "primary_tokens": [item.to_dict() for item in self.primary_tokens],
            "word_records_json_b64": base64.b64encode(self.word_records_json).decode("ascii"),
            "vocabulary_outcome": self.vocabulary_outcome,
            "candidate_regions_json_b64": base64.b64encode(self.candidate_regions_json).decode("ascii"),
        }
        if include_sensitive_text:
            payload["transcript"] = self.transcript
            payload["token_strings"] = list(self.token_strings)
        else:
            payload["transcript_sha256"] = hashlib.sha256(self.transcript.encode()).hexdigest()
            payload["token_strings_sha256"] = hashlib.sha256(canonical_json_bytes(list(self.token_strings))).hexdigest()
        return payload

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "AuditedResult":
        if "transcript" not in value or "token_strings" not in value:
            raise ValueError("an in-memory parity result must include exact text and token strings")
        return cls(
            transcript=str(value["transcript"]),
            primary_tokens=tuple(
                RawTokenWindow.from_dict(item) for item in value["primary_tokens"]
            ),
            token_strings=tuple(str(item) for item in value["token_strings"]),
            word_records_json=base64.b64decode(
                value["word_records_json_b64"], validate=True
            ),
            vocabulary_outcome=str(value["vocabulary_outcome"]),
            candidate_regions_json=base64.b64decode(
                value["candidate_regions_json_b64"], validate=True
            ),
        )
