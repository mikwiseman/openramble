#!/usr/bin/env python3
"""Fail-closed one-shot evaluator for candidate-triggered shipping fallback."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import math
import os
import random
import statistics
import unicodedata
from pathlib import Path


CANDIDATE_OUTCOMES = {
    "candidate_no_usable_evidence",
    "rescored_unmodified",
    "rescored_modified",
}
KNOWN_VOCABULARY_OUTCOMES = CANDIDATE_OUTCOMES | {"no_candidate", "unmodified"}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold().replace("ё", "е")
    output = []
    for character in text:
        category = unicodedata.category(character)
        output.append(" " if category[0] in ("P", "S", "Z", "C") else character)
    return " ".join("".join(output).split())


def edit_distance(left: list[str], right: list[str]) -> int:
    if len(left) < len(right):
        left, right = right, left
    previous = list(range(len(right) + 1))
    for left_index, left_item in enumerate(left, 1):
        current = [left_index]
        for right_index, right_item in enumerate(right, 1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[right_index] + 1,
                    previous[right_index - 1] + (left_item != right_item),
                )
            )
        previous = current
    return previous[-1]


def score(reference: str, hypothesis: str) -> dict:
    normalized_reference = normalize(reference)
    normalized_hypothesis = normalize(hypothesis)
    reference_words = normalized_reference.split()
    hypothesis_words = normalized_hypothesis.split()
    reference_characters = list(normalized_reference.replace(" ", ""))
    hypothesis_characters = list(normalized_hypothesis.replace(" ", ""))
    return {
        "normalized_reference": normalized_reference,
        "normalized_hypothesis": normalized_hypothesis,
        "word_errors": edit_distance(reference_words, hypothesis_words),
        "word_reference_length": len(reference_words),
        "character_errors": edit_distance(reference_characters, hypothesis_characters),
        "character_reference_length": len(reference_characters),
    }


def percentile(values: list[float], quantile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    low, high = math.floor(position), math.ceil(position)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def distribution(values: list[float]) -> dict:
    return {
        "count": len(values),
        "minimum": min(values) if values else None,
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "maximum": max(values) if values else None,
        "mean": statistics.fmean(values) if values else None,
    }


def load_jsonl(path: Path) -> tuple[dict[str, dict], list[str]]:
    rows = {}
    failures = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            failures.append(f"line {line_number}: invalid JSON: {error}")
            continue
        fixture_id = row.get("fixture_id")
        if not isinstance(fixture_id, str):
            failures.append(f"line {line_number}: missing fixture_id")
            continue
        if fixture_id in rows:
            failures.append(f"duplicate fixture_id: {fixture_id}")
        rows[fixture_id] = row
    return rows, failures


def transcript(item: dict) -> str:
    value = item.get("transcript")
    if not isinstance(value, str):
        value = item.get("text")
    return value if isinstance(value, str) else ""


def validate_metadata(role: str, metadata: dict, manifest_sha: str, prereg: dict) -> list[str]:
    failures = []
    if metadata.get("manifest_sha256") != manifest_sha:
        failures.append(f"{role}: manifest_sha256 mismatch")
    if metadata.get("language_hints_from_manifest") is not True:
        failures.append(f"{role}: language_hints_from_manifest must be true")
    if metadata.get("vocabulary_configured") is not True:
        failures.append(f"{role}: vocabulary_configured must be true")
    if metadata.get("product_config_sha256") != prereg["product_config"]["sha256"]:
        failures.append(f"{role}: product_config_sha256 differs from preregistration")
    for field in prereg["run_contract"]["required_nonempty_fields"]:
        if not metadata.get(field):
            failures.append(f"{role}: missing {field}")
    return failures


def validate_structure(role: str, item: dict, fixture: dict) -> list[str]:
    failures = []
    fixture_id = fixture["id"]
    if item.get("ok") is not True:
        failures.append(f"{role}:{fixture_id}: ok != true")
    if item.get("protocol_version") != 1:
        failures.append(f"{role}:{fixture_id}: protocol_version != 1")
    if item.get("prewarmed") is not True:
        failures.append(f"{role}:{fixture_id}: prewarmed != true")
    expected_fields = {
        "pcm_f32le_sha256": fixture["pcm_f32le_sha256"],
        "sample_count": fixture["sample_count"],
        "sample_rate": fixture["sample_rate"],
        "language": fixture["language_hint"],
    }
    for field, expected in expected_fields.items():
        if item.get(field) != expected:
            failures.append(f"{role}:{fixture_id}: {field} mismatch")
    if not isinstance(item.get("transcript"), str) and not isinstance(item.get("text"), str):
        failures.append(f"{role}:{fixture_id}: transcript is not a string")
    if item.get("emission_validation_failures") != []:
        failures.append(f"{role}:{fixture_id}: emission_validation_failures not empty")
    outcome = item.get("timing", {}).get("vocabulary_outcome")
    if outcome not in KNOWN_VOCABULARY_OUTCOMES:
        failures.append(f"{role}:{fixture_id}: unknown vocabulary_outcome={outcome!r}")
    invocations = item.get("timing", {}).get("ctc_inference_invocations")
    if outcome in CANDIDATE_OUTCOMES and invocations != 1:
        failures.append(f"{role}:{fixture_id}: vocabulary candidate without one CTC invocation")
    if outcome not in CANDIDATE_OUTCOMES and invocations not in (0, None):
        failures.append(f"{role}:{fixture_id}: non-candidate outcome with CTC invocation")
    for label in ("tokens", "words"):
        values = item.get(label)
        if not isinstance(values, list):
            failures.append(f"{role}:{fixture_id}: {label} is not an array")
            continue
        previous_start = -math.inf
        previous_end = -math.inf
        for index, value in enumerate(values):
            prefix = f"{role}:{fixture_id}:{label}[{index}]"
            if not isinstance(value, dict) or not isinstance(value.get("text"), str) or not value.get("text"):
                failures.append(f"{prefix}: invalid/empty text")
                continue
            try:
                start = float(value["start"])
                end = float(value["end"])
                confidence = float(value["confidence"])
            except (KeyError, TypeError, ValueError):
                failures.append(f"{prefix}: missing/non-numeric start/end/confidence")
                continue
            if not all(math.isfinite(number) for number in (start, end, confidence)):
                failures.append(f"{prefix}: non-finite value")
            if start < -1e-9 or end + 1e-9 < start or end > fixture["duration_seconds"] + 0.0800001:
                failures.append(f"{prefix}: invalid span")
            if start + 1e-9 < previous_start or end + 1e-9 < previous_end:
                failures.append(f"{prefix}: non-monotonic span")
            if not 0.0 <= confidence <= 1.0:
                failures.append(f"{prefix}: confidence outside [0,1]")
            if label == "tokens" and not isinstance(value.get("id"), int):
                failures.append(f"{prefix}: token id is not int")
            previous_start, previous_end = start, end
    return failures


def exact_alignment(left: list[dict], right: list[dict]) -> list[tuple[dict, dict]]:
    matcher = difflib.SequenceMatcher(
        a=[item["text"] for item in left],
        b=[item["text"] for item in right],
        autojunk=False,
    )
    pairs = []
    for block in matcher.get_matching_blocks():
        for offset in range(block.size):
            pairs.append((left[block.a + offset], right[block.b + offset]))
    return pairs


def alignment(fixture_ids: list[str], shipping: dict, candidate: dict, label: str) -> dict:
    pairs = []
    shipping_count = 0
    candidate_count = 0
    for fixture_id in fixture_ids:
        left = shipping[fixture_id].get(label, [])
        right = candidate[fixture_id].get(label, [])
        shipping_count += len(left)
        candidate_count += len(right)
        pairs.extend(exact_alignment(left, right))
    denominator = max(shipping_count, candidate_count)
    return {
        "shipping_count": shipping_count,
        "candidate_count": candidate_count,
        "matched_exact_text_count": len(pairs),
        "matched_fraction_symmetric": len(pairs) / denominator if denominator else 1.0,
        "absolute_start_delta_seconds": distribution(
            [abs(right["start"] - left["start"]) for left, right in pairs]
        ),
        "absolute_end_delta_seconds": distribution(
            [abs(right["end"] - left["end"]) for left, right in pairs]
        ),
        "absolute_confidence_delta": distribution(
            [abs(right["confidence"] - left["confidence"]) for left, right in pairs]
        ),
    }


def aggregate(rows: list[dict]) -> dict:
    shipping_word_errors = sum(row["shipping_score"]["word_errors"] for row in rows)
    candidate_word_errors = sum(row["candidate_score"]["word_errors"] for row in rows)
    word_length = sum(row["shipping_score"]["word_reference_length"] for row in rows)
    shipping_character_errors = sum(row["shipping_score"]["character_errors"] for row in rows)
    candidate_character_errors = sum(row["candidate_score"]["character_errors"] for row in rows)
    character_length = sum(row["shipping_score"]["character_reference_length"] for row in rows)
    return {
        "count": len(rows),
        "shipping_word_errors": shipping_word_errors,
        "candidate_word_errors": candidate_word_errors,
        "word_reference_length": word_length,
        "shipping_micro_wer": shipping_word_errors / word_length,
        "candidate_micro_wer": candidate_word_errors / word_length,
        "micro_wer_delta": (candidate_word_errors - shipping_word_errors) / word_length,
        "shipping_character_errors": shipping_character_errors,
        "candidate_character_errors": candidate_character_errors,
        "character_reference_length": character_length,
        "shipping_micro_cer": shipping_character_errors / character_length,
        "candidate_micro_cer": candidate_character_errors / character_length,
        "micro_cer_delta": (candidate_character_errors - shipping_character_errors) / character_length,
    }


def candidate_outcome(item: dict) -> bool:
    return item.get("timing", {}).get("vocabulary_outcome") in CANDIDATE_OUTCOMES


def low_integrity(item: dict) -> bool:
    timing = item.get("timing")
    return (
        item.get("ok") is not True
        or item.get("protocol_version") != 1
        or item.get("prewarmed") is not True
        or item.get("emission_validation_failures") != []
        or not isinstance(timing, dict)
        or timing.get("vocabulary_outcome") not in KNOWN_VOCABULARY_OUTCOMES
        or not isinstance(item.get("elapsed_ns"), int)
        or item.get("elapsed_ns", 0) <= 0
    )


def semantic_stability(primary: dict[str, dict], duplicate: dict[str, dict]) -> dict:
    divergent = []
    fields = ("text", "transcript", "tokens", "words", "normalized_transcript_sha256", "raw_transcript_sha256")
    for fixture_id in sorted(primary):
        if fixture_id not in duplicate:
            divergent.append(fixture_id)
            continue
        if any(primary[fixture_id].get(field) != duplicate[fixture_id].get(field) for field in fields):
            divergent.append(fixture_id)
            continue
        if primary[fixture_id].get("timing", {}).get("vocabulary_outcome") != duplicate[fixture_id].get("timing", {}).get("vocabulary_outcome"):
            divergent.append(fixture_id)
    return {"count": len(primary), "divergent_fixture_ids": divergent}


def latency_policy(shipping: dict[str, dict], candidate: dict[str, dict]) -> dict:
    shipping_values = []
    candidate_values = []
    policy_values = []
    fallback_policy_values = []
    fallback_shipping_values = []
    fallback_count = 0
    for fixture_id in sorted(shipping):
        baseline = shipping[fixture_id]["elapsed_ns"] / 1e6
        comparison = candidate[fixture_id]["elapsed_ns"] / 1e6
        fallback = candidate_outcome(candidate[fixture_id]) or low_integrity(candidate[fixture_id])
        if fallback:
            fallback_count += 1
            timing = candidate[fixture_id].get("timing", {})
            if candidate_outcome(candidate[fixture_id]) and not low_integrity(candidate[fixture_id]) and timing.get("phases_may_overlap") is False:
                phases = timing.get("phases", {})
                removable = sum(
                    (phases.get(name) or 0)
                    for name in ("ctc_model_inference_ns", "ctc_rescoring_fusion_ns")
                ) / 1e6
            else:
                removable = 0.0
            policy = comparison - removable + baseline
            fallback_policy_values.append(policy)
            fallback_shipping_values.append(baseline)
        else:
            policy = comparison
        shipping_values.append(baseline)
        candidate_values.append(comparison)
        policy_values.append(policy)
    shipping_stats = distribution(shipping_values)
    policy_stats = distribution(policy_values)
    fallback_shipping = distribution(fallback_shipping_values)
    fallback_policy = distribution(fallback_policy_values)
    return {
        "count": len(shipping),
        "fallback_count": fallback_count,
        "fallback_fraction": fallback_count / len(shipping),
        "shipping_ms": shipping_stats,
        "candidate_ms": distribution(candidate_values),
        "policy_optimistic_early_abort_ms": policy_stats,
        "stop_win_fraction": {
            field: (shipping_stats[field] - policy_stats[field]) / shipping_stats[field]
            for field in ("mean", "p50", "p95")
        },
        "fallback_subgroup": {
            "shipping_ms": fallback_shipping,
            "policy_ms": fallback_policy,
            "p95_worse_than_shipping": (
                fallback_policy["p95"] > fallback_shipping["p95"]
                if fallback_policy_values
                else False
            ),
        },
    }


def bootstrap(rows: list[dict], iterations: int, seed: str, strata: tuple[str, ...]) -> dict:
    group_keys = sorted({tuple(row[field] for field in strata) for row in rows})
    groups = [[row for row in rows if tuple(row[field] for field in strata) == key] for key in group_keys]
    rng = random.Random(int(hashlib.sha256(seed.encode("utf-8")).hexdigest()[:16], 16))
    wer_deltas = []
    cer_deltas = []
    for _ in range(iterations):
        resampled = []
        for group in groups:
            resampled.extend(group[rng.randrange(len(group))] for _ in range(len(group)))
        metrics = aggregate(resampled)
        wer_deltas.append(metrics["micro_wer_delta"])
        cer_deltas.append(metrics["micro_cer_delta"])
    return {
        "iterations": iterations,
        "seed": seed,
        "strata": list(strata),
        "wer_delta": {
            "p025": percentile(wer_deltas, 0.025),
            "p50": percentile(wer_deltas, 0.50),
            "p975": percentile(wer_deltas, 0.975),
        },
        "cer_delta": {
            "p025": percentile(cer_deltas, 0.025),
            "p50": percentile(cer_deltas, 0.50),
            "p975": percentile(cer_deltas, 0.975),
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preregistration", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--shipping-jsonl", type=Path, required=True)
    parser.add_argument("--candidate-jsonl", type=Path, required=True)
    parser.add_argument("--shipping-duplicate-jsonl", type=Path, required=True)
    parser.add_argument("--candidate-duplicate-jsonl", type=Path, required=True)
    parser.add_argument("--shipping-run-meta", type=Path, required=True)
    parser.add_argument("--candidate-run-meta", type=Path, required=True)
    parser.add_argument("--shipping-completion", type=Path, required=True)
    parser.add_argument("--candidate-completion", type=Path, required=True)
    parser.add_argument("--raw-artifact-index", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    prereg = json.loads(args.preregistration.read_text(encoding="utf-8"))
    if prereg.get("status") != "armed_and_sealed_before_inference":
        raise RuntimeError("preregistration is not armed; model execution/evaluation remains forbidden")
    if sha256_file(Path(__file__)) != prereg["analysis_protocol"]["evaluator_sha256"]:
        raise RuntimeError("evaluator SHA mismatch")
    manifest_sha = sha256_file(args.manifest)
    if manifest_sha != prereg["corpus"]["final_manifest_sha256"]:
        raise RuntimeError("final manifest SHA mismatch")
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    if manifest.get("inference_allowed") is not True:
        raise RuntimeError("manifest is not inference-armed")
    expected_counts = prereg["corpus"]["required_counts"]
    if manifest.get("counts", {}).get("by_language_duration_bin") != expected_counts:
        raise RuntimeError("manifest language/bin counts differ from preregistration")
    if manifest.get("exclusions", {}).get("selected_source_identity_overlap_count") != 0:
        raise RuntimeError("manifest source identity overlap")
    if manifest.get("exclusions", {}).get("selected_pcm_sha256_overlap_count") != 0:
        raise RuntimeError("manifest PCM overlap")

    receipt = args.output.with_suffix(args.output.suffix + ".one-shot-consumed")
    if args.output.exists() or receipt.exists():
        raise RuntimeError("one-shot evaluator output/receipt already exists")
    receipt.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(descriptor, b"consumed-before-scoring\n")
    os.close(descriptor)

    fixtures = manifest["fixtures"]
    fixture_by_id = {fixture["id"]: fixture for fixture in fixtures}
    if len(fixture_by_id) != len(fixtures):
        raise RuntimeError("duplicate fixture IDs in manifest")
    fixture_ids = sorted(fixture_by_id)
    shipping, shipping_failures = load_jsonl(args.shipping_jsonl)
    candidate, candidate_failures = load_jsonl(args.candidate_jsonl)
    shipping_duplicate, shipping_duplicate_failures = load_jsonl(args.shipping_duplicate_jsonl)
    candidate_duplicate, candidate_duplicate_failures = load_jsonl(args.candidate_duplicate_jsonl)
    integrity_failures = (
        shipping_failures
        + candidate_failures
        + shipping_duplicate_failures
        + candidate_duplicate_failures
    )
    for role, rows in (
        ("shipping", shipping),
        ("candidate", candidate),
        ("shipping_duplicate", shipping_duplicate),
        ("candidate_duplicate", candidate_duplicate),
    ):
        missing = sorted(set(fixture_ids) - set(rows))
        extra = sorted(set(rows) - set(fixture_ids))
        if missing:
            integrity_failures.append(f"{role}: missing {len(missing)} fixtures")
        if extra:
            integrity_failures.append(f"{role}: extra {len(extra)} fixtures")
    shipping_meta = json.loads(args.shipping_run_meta.read_text(encoding="utf-8"))
    candidate_meta = json.loads(args.candidate_run_meta.read_text(encoding="utf-8"))
    shipping_completion = json.loads(args.shipping_completion.read_text(encoding="utf-8"))
    candidate_completion = json.loads(args.candidate_completion.read_text(encoding="utf-8"))
    raw_index = json.loads(args.raw_artifact_index.read_text(encoding="utf-8"))
    integrity_failures.extend(validate_metadata("shipping", shipping_meta, manifest_sha, prereg))
    integrity_failures.extend(validate_metadata("candidate", candidate_meta, manifest_sha, prereg))
    for role, completion, metadata, primary, duplicate in (
        ("shipping", shipping_completion, shipping_meta, args.shipping_jsonl, args.shipping_duplicate_jsonl),
        ("candidate", candidate_completion, candidate_meta, args.candidate_jsonl, args.candidate_duplicate_jsonl),
    ):
        if not completion.get("complete") or not completion.get("shutdown_ok"):
            integrity_failures.append(f"{role}: incomplete/shutdown receipt")
        if completion.get("run_metadata_sha256") != sha256_file(
            args.shipping_run_meta if role == "shipping" else args.candidate_run_meta
        ):
            integrity_failures.append(f"{role}: run metadata receipt hash mismatch")
        hashes = completion.get("artifact_sha256", {})
        if hashes.get("primary") != sha256_file(primary):
            integrity_failures.append(f"{role}: primary receipt hash mismatch")
        if hashes.get("duplicate") != sha256_file(duplicate):
            integrity_failures.append(f"{role}: duplicate receipt hash mismatch")
    if raw_index.get("status") != "sealed_after_all_protocol_shutdown_and_before_frozen_evaluation":
        integrity_failures.append("raw artifact index is not sealed")
    if raw_index.get("manifest_sha256") != manifest_sha:
        integrity_failures.append("raw artifact index manifest hash mismatch")
    indexed = {item.get("path"): item.get("sha256") for item in raw_index.get("artifacts", [])}
    for path in (
        args.shipping_jsonl,
        args.candidate_jsonl,
        args.shipping_duplicate_jsonl,
        args.candidate_duplicate_jsonl,
        args.shipping_run_meta,
        args.candidate_run_meta,
        args.shipping_completion,
        args.candidate_completion,
    ):
        if indexed.get(str(path)) != sha256_file(path):
            integrity_failures.append(f"raw artifact index mismatch: {path}")
    for field in prereg["run_contract"]["required_equal_fields"]:
        if shipping_meta.get(field) != candidate_meta.get(field):
            integrity_failures.append(f"run metadata differs for {field}")
    if integrity_failures or any(
        set(values) != set(fixture_ids)
        for values in (shipping, candidate, shipping_duplicate, candidate_duplicate)
    ):
        report = {"decision": "REJECT", "integrity_failures": integrity_failures}
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return

    structure_failures = []
    rows = []
    vocabulary_false_negatives = []
    effective = {}
    fallback_ids = []
    for fixture_id in fixture_ids:
        fixture = fixture_by_id[fixture_id]
        shipping_structure = validate_structure("shipping", shipping[fixture_id], fixture)
        candidate_structure = validate_structure("candidate", candidate[fixture_id], fixture)
        structure_failures.extend(shipping_structure)
        structure_failures.extend(candidate_structure)
        structure_failures.extend(
            validate_structure("shipping_duplicate", shipping_duplicate[fixture_id], fixture)
        )
        structure_failures.extend(
            validate_structure("candidate_duplicate", candidate_duplicate[fixture_id], fixture)
        )
        shipping_outcome = shipping[fixture_id].get("timing", {}).get("vocabulary_outcome")
        candidate_outcome = candidate[fixture_id].get("timing", {}).get("vocabulary_outcome")
        if shipping_outcome in CANDIDATE_OUTCOMES and candidate_outcome not in CANDIDATE_OUTCOMES:
            vocabulary_false_negatives.append(fixture_id)
        fallback = candidate_outcome in CANDIDATE_OUTCOMES or bool(candidate_structure)
        if fallback:
            fallback_ids.append(fixture_id)
            effective[fixture_id] = shipping[fixture_id]
        else:
            effective[fixture_id] = candidate[fixture_id]
        shipping_score = score(fixture["reference"], transcript(shipping[fixture_id]))
        candidate_score = score(fixture["reference"], transcript(effective[fixture_id]))
        rows.append(
            {
                "fixture_id": fixture_id,
                "language": fixture["language"],
                "duration_bin": fixture["duration_bin"],
                "fallback": fallback,
                "shipping_score": shipping_score,
                "candidate_score": candidate_score,
                "extra_word_errors": candidate_score["word_errors"] - shipping_score["word_errors"],
                "extra_character_errors": candidate_score["character_errors"] - shipping_score["character_errors"],
            }
        )

    iterations = prereg["analysis_protocol"]["bootstrap_iterations"]
    seed = prereg["analysis_protocol"]["bootstrap_seed"]
    groups = {"combined": rows}
    groups.update({f"language_{language}": [row for row in rows if row["language"] == language] for language in ("en", "ru")})
    groups.update({f"bin_{bin_name}": [row for row in rows if row["duration_bin"] == bin_name] for bin_name in ("1-2", "2-3", "3-4")})
    metrics = {}
    for name, group_rows in groups.items():
        strata = ("language", "duration_bin") if name == "combined" else (("duration_bin",) if name.startswith("language_") else ("language",))
        metrics[name] = {
            "observed": aggregate(group_rows),
            "bootstrap": bootstrap(group_rows, iterations, f"{seed}|{name}", strata),
        }
    token_alignment = alignment(fixture_ids, shipping, effective, "tokens")
    word_alignment = alignment(fixture_ids, shipping, effective, "words")
    shipping_stability = semantic_stability(shipping, shipping_duplicate)
    candidate_stability = semantic_stability(candidate, candidate_duplicate)
    latency = {
        "primary": latency_policy(shipping, candidate),
        "duplicate": latency_policy(shipping_duplicate, candidate_duplicate),
    }
    thresholds = prereg["hard_gates"]
    worst = max(rows, key=lambda row: (row["extra_word_errors"], row["extra_character_errors"], row["fixture_id"]))
    gates = {
        "integrity": not integrity_failures,
        "structure": len(structure_failures) <= thresholds["invalid_token_or_word_structures_max"],
        "combined_observed_wer": metrics["combined"]["observed"]["micro_wer_delta"] <= thresholds["combined_observed_wer_delta_max"],
        "combined_bootstrap_wer": metrics["combined"]["bootstrap"]["wer_delta"]["p975"] <= thresholds["combined_bootstrap_p975_wer_delta_max"],
        "each_language_observed_wer": all(metrics[f"language_{language}"]["observed"]["micro_wer_delta"] <= thresholds["each_language_observed_wer_delta_max"] for language in ("en", "ru")),
        "each_language_bootstrap_wer": all(metrics[f"language_{language}"]["bootstrap"]["wer_delta"]["p975"] <= thresholds["each_language_bootstrap_p975_wer_delta_max"] for language in ("en", "ru")),
        "each_bin_observed_wer": all(metrics[f"bin_{bin_name}"]["observed"]["micro_wer_delta"] <= thresholds["each_duration_bin_observed_wer_delta_max"] for bin_name in ("1-2", "2-3", "3-4")),
        "each_bin_bootstrap_wer": all(metrics[f"bin_{bin_name}"]["bootstrap"]["wer_delta"]["p975"] <= thresholds["each_duration_bin_bootstrap_p975_wer_delta_max"] for bin_name in ("1-2", "2-3", "3-4")),
        "per_utterance_word_regression": worst["extra_word_errors"] < thresholds["maximum_extra_word_errors_per_utterance_exclusive"],
        "vocabulary_false_negatives": len(vocabulary_false_negatives) <= thresholds["vocabulary_candidate_false_negatives_max"],
        "token_alignment": token_alignment["matched_fraction_symmetric"] >= thresholds["token_alignment_fraction_min"],
        "word_alignment": word_alignment["matched_fraction_symmetric"] >= thresholds["word_alignment_fraction_min"],
        "token_timing": max(token_alignment["absolute_start_delta_seconds"]["p95"] or 0, token_alignment["absolute_end_delta_seconds"]["p95"] or 0) <= thresholds["aligned_timing_absolute_p95_seconds_max"],
        "word_timing": max(word_alignment["absolute_start_delta_seconds"]["p95"] or 0, word_alignment["absolute_end_delta_seconds"]["p95"] or 0) <= thresholds["aligned_timing_absolute_p95_seconds_max"],
        "token_confidence": (token_alignment["absolute_confidence_delta"]["p95"] or 0) <= thresholds["aligned_confidence_absolute_p95_max"],
        "word_confidence": (word_alignment["absolute_confidence_delta"]["p95"] or 0) <= thresholds["aligned_confidence_absolute_p95_max"],
        "shipping_duplicate_stability": not shipping_stability["divergent_fixture_ids"],
        "candidate_duplicate_stability": not candidate_stability["divergent_fixture_ids"],
        "primary_expected_mean_stop_win": latency["primary"]["stop_win_fraction"]["mean"] >= thresholds["expected_stop_win_fraction_min"],
        "duplicate_expected_mean_stop_win": latency["duplicate"]["stop_win_fraction"]["mean"] >= thresholds["expected_stop_win_fraction_min"],
        "primary_expected_p50_stop_win": latency["primary"]["stop_win_fraction"]["p50"] >= thresholds["expected_stop_win_fraction_min"],
        "duplicate_expected_p50_stop_win": latency["duplicate"]["stop_win_fraction"]["p50"] >= thresholds["expected_stop_win_fraction_min"],
        "primary_overall_p95_not_worse": latency["primary"]["policy_optimistic_early_abort_ms"]["p95"] <= latency["primary"]["shipping_ms"]["p95"],
        "duplicate_overall_p95_not_worse": latency["duplicate"]["policy_optimistic_early_abort_ms"]["p95"] <= latency["duplicate"]["shipping_ms"]["p95"],
        "primary_fallback_p95_not_worse": not latency["primary"]["fallback_subgroup"]["p95_worse_than_shipping"],
        "duplicate_fallback_p95_not_worse": not latency["duplicate"]["fallback_subgroup"]["p95_worse_than_shipping"],
    }
    report = {
        "schema_version": 1,
        "decision": "INTEGRATE" if all(gates.values()) else "REJECT",
        "gates": gates,
        "thresholds": thresholds,
        "metrics": metrics,
        "per_utterance_regression_distribution": {
            "extra_word_errors": distribution([row["extra_word_errors"] for row in rows]),
            "extra_character_errors": distribution([row["extra_character_errors"] for row in rows]),
        },
        "worst_utterance": worst,
        "token_alignment": token_alignment,
        "word_alignment": word_alignment,
        "fallback": {
            "count": len(fallback_ids),
            "fraction": len(fallback_ids) / len(fixture_ids),
            "fixture_ids": fallback_ids,
            "selection_rule": "candidate vocabulary outcome or structural invalidity only",
        },
        "latency": latency,
        "duplicate_stability": {
            "shipping": shipping_stability,
            "candidate": candidate_stability,
        },
        "structure_failures": structure_failures,
        "vocabulary_candidate_false_negatives": vocabulary_false_negatives,
        "artifact_hashes": {
            "preregistration": sha256_file(args.preregistration),
            "manifest": manifest_sha,
            "shipping_jsonl": sha256_file(args.shipping_jsonl),
            "candidate_jsonl": sha256_file(args.candidate_jsonl),
            "shipping_duplicate_jsonl": sha256_file(args.shipping_duplicate_jsonl),
            "candidate_duplicate_jsonl": sha256_file(args.candidate_duplicate_jsonl),
            "shipping_run_meta": sha256_file(args.shipping_run_meta),
            "candidate_run_meta": sha256_file(args.candidate_run_meta),
            "shipping_completion": sha256_file(args.shipping_completion),
            "candidate_completion": sha256_file(args.candidate_completion),
            "raw_artifact_index": sha256_file(args.raw_artifact_index),
            "evaluator": sha256_file(Path(__file__)),
        },
    }
    temporary = args.output.with_suffix(args.output.suffix + ".part")
    temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, args.output)


if __name__ == "__main__":
    main()
