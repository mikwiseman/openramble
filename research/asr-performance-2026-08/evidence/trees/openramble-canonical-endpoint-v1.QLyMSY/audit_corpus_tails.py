#!/usr/bin/env python3
"""Read-only PCM tail audit for the sealed dominant-short corpus.

This deliberately does not infer speech endpoints. Energy summaries are only
diagnostics; without independent endpoint annotations they cannot validate a
VAD cut.
"""

from __future__ import annotations

import argparse
import array
import hashlib
import json
import math
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path


SAMPLE_RATE = 16_000
FRAME_SAMPLES = 160  # 10 ms, anchored backwards from physical EOF.
THRESHOLDS = (0.0001, 0.0005, 0.001, 0.002, 0.005)
TAIL_WINDOWS_MS = (100, 250, 500, 750)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * q
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def rms(samples: list[float]) -> float:
    if not samples:
        return 0.0
    return math.sqrt(math.fsum(value * value for value in samples) / len(samples))


def trailing_frame_ms(samples: list[float], threshold: float) -> int:
    full_frames = len(samples) // FRAME_SAMPLES
    count = 0
    for frame_index in range(full_frames - 1, -1, -1):
        end = len(samples) - (full_frames - 1 - frame_index) * FRAME_SAMPLES
        start = end - FRAME_SAMPLES
        if rms(samples[start:end]) > threshold:
            break
        count += 1
    return count * 10


def summarize(values: list[float]) -> dict[str, float | int | None]:
    return {
        "count": len(values),
        "min": min(values) if values else None,
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "max": max(values) if values else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    manifest_bytes = args.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list) or len(fixtures) != 204:
        raise SystemExit("fail-closed: expected exact 204-row fixtures array")

    all_keys = set().union(*(fixture.keys() for fixture in fixtures))
    negative_annotation_markers = {"no_forced_alignment"}
    endpoint_annotation_keys = sorted(
        key for key in all_keys
        if key not in negative_annotation_markers
        and any(token in key.lower() for token in ("speech_end", "speech_start", "alignment", "segment"))
    )
    if endpoint_annotation_keys:
        raise SystemExit(
            "fail-closed: unexpected endpoint-like fields require manual schema review: "
            + ",".join(endpoint_annotation_keys)
        )

    rows = []
    duplicate_pcm = Counter()
    grouped_tail_ms: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    for fixture in fixtures:
        pcm_path = Path(fixture["pcm_path"])
        payload = pcm_path.read_bytes()
        actual_sha = sha256_bytes(payload)
        if actual_sha != fixture["pcm_f32le_sha256"]:
            raise SystemExit(f"fail-closed: PCM SHA mismatch: {fixture['id']}")
        if len(payload) != int(fixture["sample_count"]) * 4:
            raise SystemExit(f"fail-closed: PCM byte/sample mismatch: {fixture['id']}")
        if int(fixture["sample_rate"]) != SAMPLE_RATE:
            raise SystemExit(f"fail-closed: sample-rate mismatch: {fixture['id']}")

        values_array = array.array("f")
        values_array.frombytes(payload)
        if sys.byteorder != "little":
            values_array.byteswap()
        samples = values_array.tolist()
        if not all(math.isfinite(value) for value in samples):
            raise SystemExit(f"fail-closed: non-finite PCM: {fixture['id']}")
        duplicate_pcm[actual_sha] += 1

        exact_zero_samples = 0
        for value in reversed(samples):
            if value != 0.0:
                break
            exact_zero_samples += 1

        low_energy_ms = {
            f"rms_le_{threshold:g}": trailing_frame_ms(samples, threshold)
            for threshold in THRESHOLDS
        }
        tail_windows = {}
        for milliseconds in TAIL_WINDOWS_MS:
            count = min(len(samples), milliseconds * SAMPLE_RATE // 1000)
            tail = samples[-count:] if count else []
            tail_windows[str(milliseconds)] = {
                "rms": rms(tail),
                "peak": max((abs(value) for value in tail), default=0.0),
            }

        source_group = "common_voice" if "common-voice" in fixture["id"] else "fleurs"
        row = {
            "id": fixture["id"],
            "language": fixture["language"],
            "duration_bin": fixture["duration_bin"],
            "source_group": source_group,
            "sample_count": len(samples),
            "pcm_sha256": actual_sha,
            "exact_zero_tail_ms": exact_zero_samples * 1000.0 / SAMPLE_RATE,
            "trailing_low_energy_ms": low_energy_ms,
            "tail_windows_ms": tail_windows,
        }
        rows.append(row)
        group_key = f"{fixture['language']}|{fixture['duration_bin']}|{source_group}"
        for threshold_key, milliseconds in low_energy_ms.items():
            grouped_tail_ms[group_key][threshold_key].append(float(milliseconds))

    if any(count != 1 for count in duplicate_pcm.values()):
        raise SystemExit("fail-closed: duplicate PCM digest")

    aggregate = {}
    for threshold in THRESHOLDS:
        key = f"rms_le_{threshold:g}"
        values = [float(row["trailing_low_energy_ms"][key]) for row in rows]
        aggregate[key] = {
            "distribution_ms": summarize(values),
            "at_least_256ms": sum(value >= 256 for value in values),
            "at_least_512ms": sum(value >= 512 for value in values),
            "at_least_768ms": sum(value >= 768 for value in values),
        }

    groups = {
        group_key: {
            threshold_key: summarize(values)
            for threshold_key, values in sorted(thresholds.items())
        }
        for group_key, thresholds in sorted(grouped_tail_ms.items())
    }
    report = {
        "schema_version": 1,
        "manifest": {
            "path": str(args.manifest),
            "sha256": sha256_bytes(manifest_bytes),
            "fixture_count": len(fixtures),
            "model_outputs_inspected": False,
        },
        "method": {
            "pcm": "sealed 16kHz mono f32le; exact SHA/sample/finite validation",
            "frame": "10ms frames anchored backwards from physical EOF",
            "thresholds_are_diagnostics_only": list(THRESHOLDS),
            "not_used_as_endpoint_ground_truth": True,
            "asr_or_vad_model_inference": False,
        },
        "endpoint_annotation_audit": {
            "endpoint_annotation_fields": endpoint_annotation_keys,
            "independent_endpoint_annotations_present": False,
            "forced_alignment_present": False,
            "manual_endpoint_labels_present": False,
            "verdict": "cannot_validate_endpoint_cuts",
        },
        "aggregate": aggregate,
        "groups": groups,
        "rows": rows,
        "decision_relevance": {
            "energy_can_show_physical_low-energy_suffixes": True,
            "energy_cannot_prove_last_reference_phone_is_before_a_cut": True,
            "corpus_endpoint_coverage_gate_pass": False,
            "reason": "The frozen 204 corpus has utterance references but no independent speech-end or phoneme/word timing annotations.",
        },
    }
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
