#!/usr/bin/env python3
"""Prepare deterministic endpoint-cache falsification fixtures.

This is intentionally independent of Core ML.  It parses afconvert-produced
mono 16 kHz Float32 WAVs, creates raw stop variants, applies a tiny deterministic
energy endpoint canonicalizer, and records exact content/parameter digests.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import struct
from dataclasses import asdict, dataclass


SAMPLE_RATE = 16_000
FRAME_SAMPLES = 160  # 10 ms
TRAILING_SECONDS = (0.0, 0.1, 0.25, 0.5, 1.0)


@dataclass(frozen=True)
class Fixture:
    fixture_id: str
    wav_name: str
    language: str
    vocabulary: bool


FIXTURES = (
    Fixture("libri", "libri.wav", "en", False),
    Fixture("voices", "voices.wav", "en", False),
    Fixture("ru1", "ru1.wav", "ru", False),
    Fixture("ru6", "ru6.wav", "ru", False),
    Fixture("terms", "terms.wav", "ru", True),
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_float_wave(path: pathlib.Path) -> list[float]:
    data = path.read_bytes()
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError(f"not a little-endian RIFF/WAVE: {path}")

    offset = 12
    fmt: bytes | None = None
    payload: bytes | None = None
    while offset + 8 <= len(data):
        chunk_id = data[offset : offset + 4]
        chunk_size = struct.unpack_from("<I", data, offset + 4)[0]
        start = offset + 8
        end = start + chunk_size
        if end > len(data):
            raise ValueError(f"truncated WAV chunk in {path}")
        if chunk_id == b"fmt ":
            fmt = data[start:end]
        elif chunk_id == b"data":
            payload = data[start:end]
        offset = end + (chunk_size & 1)

    if fmt is None or payload is None or len(fmt) < 16:
        raise ValueError(f"missing fmt/data chunk in {path}")
    format_tag, channels, sample_rate, _, block_align, bits = struct.unpack_from(
        "<HHIIHH", fmt, 0
    )
    if not (
        format_tag == 3
        and channels == 1
        and sample_rate == SAMPLE_RATE
        and block_align == 4
        and bits == 32
        and len(payload) % 4 == 0
    ):
        raise ValueError(
            f"expected mono 16 kHz IEEE Float32, got tag={format_tag} "
            f"channels={channels} rate={sample_rate} align={block_align} bits={bits}"
        )
    return list(struct.unpack(f"<{len(payload) // 4}f", payload))


def pcm_bytes(samples: list[float]) -> bytes:
    if not all(math.isfinite(sample) for sample in samples):
        raise ValueError("non-finite PCM")
    return struct.pack(f"<{len(samples)}f", *samples)


def frame_rms(frame: list[float]) -> float:
    if not frame:
        return 0.0
    return math.sqrt(sum(sample * sample for sample in frame) / len(frame))


def last_active_frame(samples: list[float], threshold: float) -> int | None:
    last: int | None = None
    for start in range(0, len(samples), FRAME_SAMPLES):
        frame = samples[start : start + FRAME_SAMPLES]
        if frame_rms(frame) > threshold:
            last = start // FRAME_SAMPLES
    return last


def canonicalize(
    samples: list[float], threshold: float, postroll_samples: int
) -> tuple[list[float], int, int]:
    """Trim only frames strictly after deterministic postroll.

    Returns canonical samples, last-active end sample, and observed trailing
    silence samples.  A final partial frame is treated as a full frame for the
    conservative silence-duration calculation.
    """

    last = last_active_frame(samples, threshold)
    if last is None:
        return samples[: min(len(samples), postroll_samples)], 0, len(samples)
    active_end = min(len(samples), (last + 1) * FRAME_SAMPLES)
    canonical_end = min(len(samples), active_end + postroll_samples)
    return samples[:canonical_end], active_end, max(0, len(samples) - active_end)


def endpoint_digest(samples: list[float], parameters: dict[str, object]) -> str:
    parameter_bytes = json.dumps(
        parameters, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    digest = hashlib.sha256()
    digest.update(struct.pack("<Q", len(parameter_bytes)))
    digest.update(parameter_bytes)
    digest.update(pcm_bytes(samples))
    return digest.hexdigest()


def strongest_excerpt(samples: list[float], count: int) -> list[float]:
    count = min(count, len(samples))
    if count == len(samples):
        return list(samples)
    stride = FRAME_SAMPLES
    best_start = 0
    best_energy = -1.0
    for start in range(0, len(samples) - count + 1, stride):
        excerpt = samples[start : start + count]
        energy = sum(sample * sample for sample in excerpt)
        if energy > best_energy:
            best_energy = energy
            best_start = start
    return samples[best_start : best_start + count]


def write_pcm(path: pathlib.Path, samples: list[float]) -> str:
    data = pcm_bytes(samples)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return sha256(data)


def tail_stats(samples: list[float]) -> dict[str, object]:
    durations = (0.1, 0.25, 0.5, 1.0)
    values: dict[str, object] = {}
    for seconds in durations:
        count = min(len(samples), round(seconds * SAMPLE_RATE))
        tail = samples[-count:]
        values[f"{seconds:g}s"] = {
            "rms": frame_rms(tail),
            "peak": max((abs(value) for value in tail), default=0.0),
        }
    return values


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--threshold", type=float, default=0.002)
    parser.add_argument("--postroll", type=float, default=0.25)
    parser.add_argument("--settle", type=float, default=0.5)
    args = parser.parse_args()

    root = args.root.resolve()
    source_dir = root / "pcm"
    variant_dir = root / "variants"
    postroll_samples = round(args.postroll * SAMPLE_RATE)
    settle_samples = round(args.settle * SAMPLE_RATE)

    common_parameters: dict[str, object] = {
        "schema": 1,
        "sample_rate": SAMPLE_RATE,
        "canonicalizer": "rms-10ms-last-active-fixed-postroll",
        "rms_threshold": args.threshold,
        "postroll_samples": postroll_samples,
        "settle_samples": settle_samples,
        "model_revision": "aed02740059203c4a87495924f685de3722ae9ce",
        "fluid_audio_revision": "ee9a7f12d91710da53de6d75f8b7160e09eccee4",
        "vocabulary_model_revision": "accdafd8cf8a2ff1cabe3c11e54416b405d409aa",
        "vocabulary_scheduling": "candidateRegions",
        "vocabulary_min_similarity": 0.65,
        "vocabulary_bias_weight": 3.0,
        "encoder": "palettized6bit",
        "encoder_placement": "automatic",
        "parallel_chunk_concurrency": 4,
        "max_tokens_per_chunk": 600,
        "dual_decode": False,
        "mel_chunk_context": False,
    }

    report: dict[str, object] = {
        "schema_version": 1,
        "canonicalizer": {
            "frame_samples": FRAME_SAMPLES,
            "rms_threshold": args.threshold,
            "postroll_seconds": args.postroll,
            "settle_seconds": args.settle,
        },
        "fixtures": [],
        "parameter_falsification": [],
    }

    for fixture in FIXTURES:
        base = read_float_wave(source_dir / fixture.wav_name)
        fixture_parameters = {
            **common_parameters,
            "language": fixture.language,
            "vocabulary_enabled": fixture.vocabulary,
            "vocabulary_revision": 1 if fixture.vocabulary else 0,
            "vocabulary_terms_digest": (
                "developer-default-v1" if fixture.vocabulary else "none"
            ),
        }
        base_path = variant_dir / fixture.fixture_id / "base.f32le"
        base_hash = write_pcm(base_path, base)
        fixture_report: dict[str, object] = {
            "fixture": asdict(fixture),
            "base_path": str(base_path),
            "base_sample_count": len(base),
            "base_duration_seconds": len(base) / SAMPLE_RATE,
            "base_pcm_sha256": base_hash,
            "tail_stats": tail_stats(base),
            "variants": [],
        }

        for seconds in TRAILING_SECONDS:
            suffix_count = round(seconds * SAMPLE_RATE)
            raw = base + [0.0] * suffix_count
            label = f"append-zero-{int(seconds * 1000):04d}ms"
            raw_path = variant_dir / fixture.fixture_id / f"{label}.f32le"
            raw_hash = write_pcm(raw_path, raw)

            canonical, active_end, trailing = canonicalize(
                raw, args.threshold, postroll_samples
            )
            canonical_path = (
                variant_dir / fixture.fixture_id / f"{label}-canonical.f32le"
            )
            canonical_hash = write_pcm(canonical_path, canonical)
            final_digest = endpoint_digest(canonical, fixture_parameters)
            eligible = trailing >= settle_samples

            snapshot_path: str | None = None
            snapshot_hash: str | None = None
            snapshot_digest: str | None = None
            digest_matches = False
            if eligible:
                snapshot_source_end = min(len(raw), active_end + settle_samples)
                snapshot_source = raw[:snapshot_source_end]
                snapshot, _, _ = canonicalize(
                    snapshot_source, args.threshold, postroll_samples
                )
                snapshot_file = (
                    variant_dir / fixture.fixture_id / f"{label}-snapshot.f32le"
                )
                snapshot_path = str(snapshot_file)
                snapshot_hash = write_pcm(snapshot_file, snapshot)
                snapshot_digest = endpoint_digest(snapshot, fixture_parameters)
                digest_matches = snapshot_digest == final_digest

            fixture_report["variants"].append(
                {
                    "kind": "append_zero",
                    "seconds": seconds,
                    "label": label,
                    "raw_path": str(raw_path),
                    "raw_sample_count": len(raw),
                    "raw_pcm_sha256": raw_hash,
                    "canonical_path": str(canonical_path),
                    "canonical_sample_count": len(canonical),
                    "canonical_pcm_sha256": canonical_hash,
                    "last_active_end_sample": active_end,
                    "observed_trailing_silence_samples": trailing,
                    "endpoint_eligible": eligible,
                    "snapshot_path": snapshot_path,
                    "snapshot_pcm_sha256": snapshot_hash,
                    "snapshot_digest": snapshot_digest,
                    "final_digest": final_digest,
                    "digest_matches": digest_matches,
                }
            )

        for seconds in TRAILING_SECONDS[1:]:
            trim_count = round(seconds * SAMPLE_RATE)
            trimmed = base[: max(1, len(base) - trim_count)]
            label = f"trim-{int(seconds * 1000):04d}ms"
            raw_path = variant_dir / fixture.fixture_id / f"{label}.f32le"
            raw_hash = write_pcm(raw_path, trimmed)
            canonical, active_end, trailing = canonicalize(
                trimmed, args.threshold, postroll_samples
            )
            canonical_path = (
                variant_dir / fixture.fixture_id / f"{label}-canonical.f32le"
            )
            canonical_hash = write_pcm(canonical_path, canonical)
            fixture_report["variants"].append(
                {
                    "kind": "trim",
                    "seconds": seconds,
                    "label": label,
                    "raw_path": str(raw_path),
                    "raw_sample_count": len(trimmed),
                    "raw_pcm_sha256": raw_hash,
                    "canonical_path": str(canonical_path),
                    "canonical_sample_count": len(canonical),
                    "canonical_pcm_sha256": canonical_hash,
                    "last_active_end_sample": active_end,
                    "observed_trailing_silence_samples": trailing,
                    "endpoint_eligible": trailing >= settle_samples,
                    "final_digest": endpoint_digest(canonical, fixture_parameters),
                }
            )

        # A resumed-speech adversary must invalidate an earlier endpoint result.
        first_endpoint = base + [0.0] * settle_samples
        snapshot, _, _ = canonicalize(
            first_endpoint, args.threshold, postroll_samples
        )
        resumed = (
            first_endpoint
            + strongest_excerpt(base, round(0.2 * SAMPLE_RATE))
            + [0.0] * settle_samples
        )
        resumed_canonical, _, _ = canonicalize(
            resumed, args.threshold, postroll_samples
        )
        fixture_report["resumed_speech"] = {
            "snapshot_digest": endpoint_digest(snapshot, fixture_parameters),
            "final_digest": endpoint_digest(resumed_canonical, fixture_parameters),
            "digest_matches": endpoint_digest(snapshot, fixture_parameters)
            == endpoint_digest(resumed_canonical, fixture_parameters),
        }
        report["fixtures"].append(fixture_report)

        base_canonical, _, _ = canonicalize(base, args.threshold, postroll_samples)
        base_digest = endpoint_digest(base_canonical, fixture_parameters)
        for changed_field, changed_value in (
            ("language", "ru" if fixture.language == "en" else "en"),
            ("model_revision", "different-model"),
            ("vocabulary_revision", 2),
            ("vocabulary_terms_digest", "different-terms"),
        ):
            changed = {**fixture_parameters, changed_field: changed_value}
            report["parameter_falsification"].append(
                {
                    "fixture_id": fixture.fixture_id,
                    "changed_field": changed_field,
                    "baseline_digest": base_digest,
                    "changed_digest": endpoint_digest(base_canonical, changed),
                    "digest_matches": base_digest
                    == endpoint_digest(base_canonical, changed),
                }
            )

    output = root / "prepared-fixtures.json"
    output.write_text(
        json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(output)


if __name__ == "__main__":
    main()
