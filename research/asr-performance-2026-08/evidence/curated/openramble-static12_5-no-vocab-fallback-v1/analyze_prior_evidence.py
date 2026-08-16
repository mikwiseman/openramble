#!/usr/bin/env python3
"""CPU-only post-hoc audit of frozen 12.5s/15s and engineering evidence."""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import math
import os
import statistics
import unicodedata
from pathlib import Path


ROOT_300 = Path("$TMP/openramble-intermediate-quality-gate")
ROOT_122 = Path("$TMP/openramble-short-quality-gate")
CANDIDATE_OUTCOMES = {
    "candidate_no_usable_evidence",
    "rescored_unmodified",
    "rescored_modified",
}
KNOWN_OUTCOMES = CANDIDATE_OUTCOMES | {"no_candidate", "unmodified"}

INPUTS = {
    "holdout300_manifest": (
        ROOT_300 / "corpus/manifest.json",
        "bf7e768a882b7a826ab657c32ceb71e5e5a6589833fe1aaf8ab82684c140b9c7",
    ),
    "holdout300_shipping_primary": (
        ROOT_300 / "raw/shipping.primary.jsonl",
        "2395eb63d611536cc9c4e9c1d0cf0aa041f38912c35f4287835d39dd06683591",
    ),
    "holdout300_shipping_duplicate": (
        ROOT_300 / "raw/shipping.duplicate.jsonl",
        "f2b92733b3ab52f0b715e3a78becdda9cd623fcba2241e8de65e52835a1e341e",
    ),
    "holdout300_candidate_primary": (
        ROOT_300 / "raw/candidate-12.5.primary.jsonl",
        "8d1ea4b35f64a1c507b17a0065e4c7005edbd97c5ae658df3708ac9f7bca18a7",
    ),
    "holdout300_candidate_duplicate": (
        ROOT_300 / "raw/candidate-12.5.duplicate.jsonl",
        "9a61df7364be3491b8108ceadc24ae31bfc3438b15791ced1fd555fa4d67dd4e",
    ),
    "holdout300_gate": (
        ROOT_300 / "reports/shape-12.5-gate.json",
        "e1d3d6bd7c67e7fd04c915d1ab25a3625327f4689f98e066ff4ef37bf028e815",
    ),
    "holdout300_posthoc": (
        ROOT_300 / "reports/posthoc-analysis.json",
        "fa232c14a98d3ddcc64df784b2217dc43555d51184e4e7bc2e0d3185e087be01",
    ),
    "engineering128_manifest": (
        ROOT_122 / "corpus/manifest.json",
        "fd8fe15b32d9dbe84452f43ac02b3500b9f2b44baf646dd682600896a7f31771",
    ),
    "engineering128_shipping": (
        ROOT_122 / "reports/shipping.jsonl",
        "b8898a3f5c6bb32dbcca6e79a87fd5a59ca8496382b6ccc29e8381fb88209dcb",
    ),
    "engineering128_short": (
        ROOT_122 / "reports/short.jsonl",
        "e28083cd0313e05c7a6c43aa0e3f23062cc6c59a6de82d7bf3b9e74088a3cd35",
    ),
    "engineering122_gate": (
        ROOT_122 / "reports/quality-gate.json",
        "a8dcd5b1d2ef977bd1d959b216a471a5611d0f3ecc9def84d5012bb4c0a8358e",
    ),
    "engineering122_risk": (
        ROOT_122 / "reports/risk-gate-analysis.json",
        "db72688d80d2800276a0bf75b394812c4151eda2d58b5dc75e3672bdea321649",
    ),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_jsonl(path: Path) -> dict[str, dict]:
    result: dict[str, dict] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        item = json.loads(line)
        fixture_id = item.get("fixture_id")
        if not isinstance(fixture_id, str) or fixture_id in result:
            raise RuntimeError(f"{path}: bad/duplicate fixture_id at line {line_number}")
        result[fixture_id] = item
    return result


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold().replace("ё", "е")
    output = []
    for character in text:
        output.append(" " if unicodedata.category(character)[0] in "PSZC" else character)
    return " ".join("".join(output).split())


def distance(left: list[str], right: list[str]) -> int:
    if len(left) < len(right):
        left, right = right, left
    previous = list(range(len(right) + 1))
    for left_index, left_value in enumerate(left, 1):
        current = [left_index]
        for right_index, right_value in enumerate(right, 1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[right_index] + 1,
                    previous[right_index - 1] + (left_value != right_value),
                )
            )
        previous = current
    return previous[-1]


def score(reference: str, hypothesis: str) -> dict:
    reference = normalize(reference)
    hypothesis = normalize(hypothesis)
    words = reference.split()
    characters = list(reference.replace(" ", ""))
    return {
        "word_errors": distance(words, hypothesis.split()),
        "word_reference_length": len(words),
        "character_errors": distance(characters, list(hypothesis.replace(" ", ""))),
        "character_reference_length": len(characters),
    }


def percentile(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    low, high = math.floor(position), math.ceil(position)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def distribution(values: list[float]) -> dict:
    return {
        "count": len(values),
        "min": min(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "max": max(values),
        "mean": statistics.fmean(values),
    }


def candidate(item: dict) -> bool:
    return item.get("timing", {}).get("vocabulary_outcome") in CANDIDATE_OUTCOMES


def structural_failures(item: dict, fixture: dict | None = None) -> list[str]:
    failures = []
    if item.get("ok") is not True or item.get("protocol_version") != 1:
        failures.append("protocol envelope")
    if item.get("prewarmed") is not True:
        failures.append("not prewarmed")
    if item.get("emission_validation_failures") != []:
        failures.append("emission validation")
    timing = item.get("timing")
    if not isinstance(timing, dict):
        failures.append("timing missing")
        return failures
    outcome = timing.get("vocabulary_outcome")
    invocations = timing.get("ctc_inference_invocations")
    if outcome not in KNOWN_OUTCOMES:
        failures.append("unknown vocabulary outcome")
    if outcome in CANDIDATE_OUTCOMES and invocations != 1:
        failures.append("candidate/CTC mismatch")
    if outcome not in CANDIDATE_OUTCOMES and invocations not in (0, None):
        failures.append("noncandidate/CTC mismatch")
    if timing.get("phases_may_overlap") is not False:
        failures.append("overlapping phases")
    elapsed = item.get("elapsed_ns")
    if not isinstance(elapsed, int) or elapsed <= 0 or timing.get("total_wall_ns") != elapsed:
        failures.append("wall timing")
    if fixture is not None:
        expected = {
            "pcm_f32le_sha256": fixture["pcm_f32le_sha256"],
            "sample_count": fixture["sample_count"],
            "sample_rate": fixture["sample_rate"],
            "language": fixture["language_hint"],
        }
        for field, value in expected.items():
            if item.get(field) != value:
                failures.append(f"{field} mismatch")
    duration = (fixture["duration_seconds"] if fixture else item.get("sample_count", 0) / 16000)
    for label in ("tokens", "words"):
        values = item.get(label)
        if not isinstance(values, list):
            failures.append(f"{label} missing")
            continue
        previous_start = previous_end = -math.inf
        for value in values:
            try:
                start = float(value["start"])
                end = float(value["end"])
                confidence = float(value["confidence"])
            except (KeyError, TypeError, ValueError):
                failures.append(f"{label} numeric fields")
                break
            if not all(math.isfinite(x) for x in (start, end, confidence)):
                failures.append(f"{label} nonfinite")
                break
            if start < -1e-9 or end + 1e-9 < start or end > duration + 0.0800001:
                failures.append(f"{label} span")
                break
            if start + 1e-9 < previous_start or end + 1e-9 < previous_end:
                failures.append(f"{label} order")
                break
            if not 0 <= confidence <= 1:
                failures.append(f"{label} confidence")
                break
            previous_start, previous_end = start, end
    return failures


def aggregate_quality(rows: list[dict]) -> dict:
    shipping_word_errors = sum(row["shipping"]["word_errors"] for row in rows)
    effective_word_errors = sum(row["effective"]["word_errors"] for row in rows)
    word_length = sum(row["shipping"]["word_reference_length"] for row in rows)
    shipping_character_errors = sum(row["shipping"]["character_errors"] for row in rows)
    effective_character_errors = sum(row["effective"]["character_errors"] for row in rows)
    character_length = sum(row["shipping"]["character_reference_length"] for row in rows)
    deltas = [row["effective"]["word_errors"] - row["shipping"]["word_errors"] for row in rows]
    character_deltas = [
        row["effective"]["character_errors"] - row["shipping"]["character_errors"]
        for row in rows
    ]
    return {
        "count": len(rows),
        "fallback_count": sum(row["fallback"] for row in rows),
        "fallback_fraction": sum(row["fallback"] for row in rows) / len(rows),
        "shipping_micro_wer": shipping_word_errors / word_length,
        "effective_micro_wer": effective_word_errors / word_length,
        "micro_wer_delta": (effective_word_errors - shipping_word_errors) / word_length,
        "shipping_micro_cer": shipping_character_errors / character_length,
        "effective_micro_cer": effective_character_errors / character_length,
        "micro_cer_delta": (effective_character_errors - shipping_character_errors) / character_length,
        "net_word_error_delta": sum(deltas),
        "net_character_error_delta": sum(character_deltas),
        "word_error_delta_distribution": {
            str(key): value for key, value in sorted(collections.Counter(deltas).items())
        },
        "utterances_improved": sum(value < 0 for value in deltas),
        "utterances_tied": sum(value == 0 for value in deltas),
        "utterances_regressed": sum(value > 0 for value in deltas),
        "residual_plus_two_or_more_ids": [
            row["fixture_id"] for row, value in zip(rows, deltas) if value >= 2
        ],
    }


def latency_policy(shipping: dict[str, dict], short: dict[str, dict]) -> dict:
    if set(shipping) != set(short):
        raise RuntimeError("latency fixture sets differ")
    baseline_values = []
    short_values = []
    optimistic_values = []
    conservative_values = []
    fallback_optimistic = []
    fallback_baseline = []
    fallback_count = 0
    for fixture_id in sorted(shipping):
        baseline = shipping[fixture_id]["elapsed_ns"] / 1e6
        short_wall = short[fixture_id]["elapsed_ns"] / 1e6
        invalid = bool(structural_failures(short[fixture_id]))
        fallback = candidate(short[fixture_id]) or invalid
        baseline_values.append(baseline)
        short_values.append(short_wall)
        if fallback:
            fallback_count += 1
            phases = short[fixture_id]["timing"].get("phases", {})
            removable_ctc = sum(
                (phases.get(name) or 0)
                for name in ("ctc_model_inference_ns", "ctc_rescoring_fusion_ns")
            ) / 1e6
            prefix = short_wall - removable_ctc if candidate(short[fixture_id]) and not invalid else short_wall
            optimistic = prefix + baseline
            conservative = short_wall + baseline
            fallback_optimistic.append(optimistic)
            fallback_baseline.append(baseline)
        else:
            optimistic = conservative = short_wall
        optimistic_values.append(optimistic)
        conservative_values.append(conservative)
    baseline_stats = distribution(baseline_values)
    short_stats = distribution(short_values)
    optimistic_stats = distribution(optimistic_values)
    conservative_stats = distribution(conservative_values)
    return {
        "count": len(shipping),
        "fallback_count": fallback_count,
        "fallback_fraction": fallback_count / len(shipping),
        "shipping_ms": baseline_stats,
        "short_ms": short_stats,
        "policy_optimistic_early_candidate_abort_ms": optimistic_stats,
        "policy_conservative_full_short_then_shipping_ms": conservative_stats,
        "optimistic_stop_win_fraction": {
            field: (baseline_stats[field] - optimistic_stats[field]) / baseline_stats[field]
            for field in ("mean", "p50", "p95")
        },
        "fallback_subgroup": {
            "shipping_ms": distribution(fallback_baseline),
            "serial_policy_optimistic_ms": distribution(fallback_optimistic),
            "p95_worse_than_shipping": percentile(fallback_optimistic, 0.95)
            > percentile(fallback_baseline, 0.95),
        },
        "arithmetic": (
            "no candidate: short wall; candidate: short wall minus only recorded short CTC model/fusion "
            "phases plus full shipping wall; invalid/low-integrity: full short wall plus full shipping wall"
        ),
    }


def semantic_stability(primary: dict[str, dict], duplicate: dict[str, dict]) -> dict:
    fields = (
        "text",
        "tokens",
        "words",
        "normalized_transcript_sha256",
        "raw_transcript_sha256",
    )
    divergent = []
    for fixture_id in sorted(primary):
        if fixture_id not in duplicate or any(primary[fixture_id].get(x) != duplicate[fixture_id].get(x) for x in fields):
            divergent.append(fixture_id)
        elif primary[fixture_id].get("timing", {}).get("vocabulary_outcome") != duplicate[fixture_id].get("timing", {}).get("vocabulary_outcome"):
            divergent.append(fixture_id)
    return {"count": len(primary), "semantic_divergent_fixture_ids": divergent}


def audit_300() -> dict:
    manifest = json.loads(INPUTS["holdout300_manifest"][0].read_text(encoding="utf-8"))
    fixtures = {
        fixture["id"]: fixture
        for fixture in manifest["fixtures"]
        if "shape_12.5" in fixture["cohorts"]
    }
    shipping_primary = load_jsonl(INPUTS["holdout300_shipping_primary"][0])
    shipping_duplicate = load_jsonl(INPUTS["holdout300_shipping_duplicate"][0])
    short_primary = load_jsonl(INPUTS["holdout300_candidate_primary"][0])
    short_duplicate = load_jsonl(INPUTS["holdout300_candidate_duplicate"][0])
    if set(fixtures) != set(shipping_primary) or set(fixtures) != set(short_primary):
        raise RuntimeError("holdout300 fixture set mismatch")
    rows = []
    invalid_ids = []
    false_negatives = []
    for fixture_id in sorted(fixtures):
        fixture = fixtures[fixture_id]
        baseline = shipping_primary[fixture_id]
        comparison = short_primary[fixture_id]
        invalid = structural_failures(comparison, fixture)
        if invalid:
            invalid_ids.append({"fixture_id": fixture_id, "failures": invalid})
        if candidate(baseline) and not candidate(comparison):
            false_negatives.append(fixture_id)
        fallback = candidate(comparison) or bool(invalid)
        shipping_score = score(fixture["reference"], baseline["text"])
        short_score = score(fixture["reference"], comparison["text"])
        rows.append(
            {
                "fixture_id": fixture_id,
                "language": fixture["language"],
                "fallback": fallback,
                "shipping": shipping_score,
                "effective": shipping_score if fallback else short_score,
            }
        )
    return {
        "role": "independent_fleurs_holdout_direct_12.5s_evidence",
        "quality": {
            language: aggregate_quality(
                rows if language == "all" else [row for row in rows if row["language"] == language]
            )
            for language in ("all", "en", "ru")
        },
        "invalid_or_low_integrity_ids": invalid_ids,
        "shipping_candidate_short_none_false_negative_ids": false_negatives,
        "latency": {
            "primary": latency_policy(shipping_primary, short_primary),
            "duplicate": latency_policy(shipping_duplicate, short_duplicate),
        },
        "duplicate_stability": {
            "shipping": semantic_stability(shipping_primary, shipping_duplicate),
            "short": semantic_stability(short_primary, short_duplicate),
        },
    }


def audit_122() -> dict:
    report = json.loads(INPUTS["engineering122_gate"][0].read_text(encoding="utf-8"))
    shipping = load_jsonl(INPUTS["engineering128_shipping"][0])
    short = load_jsonl(INPUTS["engineering128_short"][0])
    rows = []
    false_negatives = []
    for comparison in report["analysis"]["comparisons"]:
        if comparison.get("vocabulary_false_negative"):
            false_negatives.append(comparison["fixture_id"])
        if not comparison.get("scored"):
            continue
        shipping_score = {
            "word_errors": comparison["shipping_score"]["wer"]["errors"],
            "word_reference_length": comparison["shipping_score"]["wer"]["reference_length"],
            "character_errors": comparison["shipping_score"]["cer"]["errors"],
            "character_reference_length": comparison["shipping_score"]["cer"]["reference_length"],
        }
        short_score = {
            "word_errors": comparison["short_score"]["wer"]["errors"],
            "word_reference_length": comparison["short_score"]["wer"]["reference_length"],
            "character_errors": comparison["short_score"]["cer"]["errors"],
            "character_reference_length": comparison["short_score"]["cer"]["reference_length"],
        }
        rows.append(
            {
                "fixture_id": comparison["fixture_id"],
                "language": comparison["language"],
                "fallback": comparison["short_candidate"],
                "shipping": shipping_score,
                "effective": shipping_score if comparison["short_candidate"] else short_score,
            }
        )
    return {
        "role": "development_only_7.5s_risk_proxy_never_pooled_with_12.5s_holdout",
        "manifest_count": 128,
        "scored_count": 122,
        "quality": {
            language: aggregate_quality(
                rows if language == "all" else [row for row in rows if row["language"] == language]
            )
            for language in ("all", "en", "ru")
        },
        "fallback_all_128": {
            "count": sum(candidate(item) for item in short.values()),
            "fraction": sum(candidate(item) for item in short.values()) / len(short),
        },
        "shipping_candidate_short_none_false_negative_ids": false_negatives,
        "latency_single_sequential_diagnostic": latency_policy(shipping, short),
        "latency_caveat": "Single sequential 7.5s quality pass; development-only directional evidence.",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    verified = {}
    for name, (path, expected) in INPUTS.items():
        actual = sha256(path)
        if actual != expected:
            raise RuntimeError(f"input hash mismatch: {name}: {actual} != {expected}")
        verified[name] = {"path": str(path), "sha256": actual}
    holdout = audit_300()
    engineering = audit_122()
    gates = {
        "holdout300_zero_false_negative": not holdout["shipping_candidate_short_none_false_negative_ids"],
        "holdout300_zero_invalid": not holdout["invalid_or_low_integrity_ids"],
        "holdout300_no_residual_plus_two": not holdout["quality"]["all"]["residual_plus_two_or_more_ids"],
        "engineering122_no_residual_plus_two": not engineering["quality"]["all"]["residual_plus_two_or_more_ids"],
        "holdout300_primary_expected_mean_stop_win_at_least_15pct": holdout["latency"]["primary"]["optimistic_stop_win_fraction"]["mean"] >= 0.15,
        "holdout300_duplicate_expected_mean_stop_win_at_least_15pct": holdout["latency"]["duplicate"]["optimistic_stop_win_fraction"]["mean"] >= 0.15,
        "holdout300_primary_expected_p50_stop_win_at_least_15pct": holdout["latency"]["primary"]["optimistic_stop_win_fraction"]["p50"] >= 0.15,
        "holdout300_duplicate_expected_p50_stop_win_at_least_15pct": holdout["latency"]["duplicate"]["optimistic_stop_win_fraction"]["p50"] >= 0.15,
        "holdout300_primary_overall_p95_not_worse": holdout["latency"]["primary"]["policy_optimistic_early_candidate_abort_ms"]["p95"] <= holdout["latency"]["primary"]["shipping_ms"]["p95"],
        "holdout300_duplicate_overall_p95_not_worse": holdout["latency"]["duplicate"]["policy_optimistic_early_candidate_abort_ms"]["p95"] <= holdout["latency"]["duplicate"]["shipping_ms"]["p95"],
        "holdout300_primary_fallback_p95_not_worse": not holdout["latency"]["primary"]["fallback_subgroup"]["p95_worse_than_shipping"],
        "holdout300_duplicate_fallback_p95_not_worse": not holdout["latency"]["duplicate"]["fallback_subgroup"]["p95_worse_than_shipping"],
    }
    result = {
        "schema_version": 1,
        "status": "cpu_only_posthoc_frozen_evidence",
        "hypothesis": "static 12.5s path unless it reports an acoustic-vocabulary candidate or an invalid/low-integrity result; then serially rerun exact shipping 15s and return shipping output",
        "selection_rule": "Candidate outcome or structural invalidity only. No confidence, duration, count, rate, or fitted threshold.",
        "quality_sets_are_not_pooled": True,
        "inputs": verified,
        "holdout300": holdout,
        "engineering122": engineering,
        "hard_gates": gates,
        "decision": "integrate" if all(gates.values()) else "reject_before_untouched_204_inference",
        "failed_hard_gates": [name for name, passed in gates.items() if not passed],
        "untouched_204_outputs_opened": False,
        "asr_or_coreml_run": False,
    }
    if args.output.exists():
        raise RuntimeError(f"refusing to overwrite {args.output}")
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, args.output)
    os.chmod(args.output, 0o444)
    print(json.dumps({"decision": result["decision"], "failed_hard_gates": result["failed_hard_gates"]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
