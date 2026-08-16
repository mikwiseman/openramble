#!/usr/bin/env python3
"""Summarize endpoint-cache parity without persisting dictated content."""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics


PARITY_FIELDS = (
    "raw_transcript_sha256",
    "normalized_transcript_sha256",
    "token_timing_sha256",
    "word_timing_sha256",
)


def first_run(report: dict, key: str) -> dict:
    return report["runs"][key][0]


def vocabulary_outcome(result: dict) -> str | None:
    timing = result.get("timing")
    return timing.get("vocabulary_outcome") if isinstance(timing, dict) else None


def differences(left: dict, right: dict) -> list[str]:
    changed = [field for field in PARITY_FIELDS if left[field] != right[field]]
    if vocabulary_outcome(left) != vocabulary_outcome(right):
        changed.append("vocabulary_outcome")
    if left["audio_duration_ns"] != right["audio_duration_ns"]:
        changed.append("audio_duration_ns")
    return changed


def summarize(path: pathlib.Path) -> dict:
    report = json.loads(path.read_text(encoding="utf-8"))
    prepared = json.loads(
        pathlib.Path(report["prepared_fixture_report"]).read_text(encoding="utf-8")
    )
    prepared_by_id = {
        item["fixture"]["fixture_id"]: item for item in prepared["fixtures"]
    }
    rows: list[dict] = []
    for analyzed_fixture in report["analysis"]["fixtures"]:
        fixture_id = analyzed_fixture["fixture_id"]
        refs = report["references"][fixture_id]
        base = first_run(report, refs["base"])
        prepared_variants = {
            item["label"]: item for item in prepared_by_id[fixture_id]["variants"]
        }
        for analyzed in analyzed_fixture["variants"]:
            label = analyzed["label"]
            raw = first_run(report, refs[f"{label}:raw"])
            canonical = first_run(report, refs[f"{label}:canonical"])
            source = prepared_variants[label]
            rows.append(
                {
                    "fixture_id": fixture_id,
                    "kind": analyzed["kind"],
                    "seconds": analyzed["seconds"],
                    "endpoint_eligible": analyzed["endpoint_eligible"],
                    "digest_matches": analyzed["digest_matches"],
                    "raw_vs_base_changed": differences(base, raw),
                    "canonical_vs_raw_changed": differences(raw, canonical),
                    "raw_vocabulary_outcome": vocabulary_outcome(raw),
                    "canonical_vocabulary_outcome": vocabulary_outcome(canonical),
                    "raw_sample_count": analyzed["raw_sample_count"],
                    "canonical_sample_count": analyzed["canonical_sample_count"],
                    "observed_trailing_silence_ms": round(
                        source["observed_trailing_silence_samples"] / 16, 3
                    ),
                    "raw_median_ms": analyzed["raw_median_elapsed_ns"] / 1e6,
                    "canonical_median_ms": analyzed["canonical_median_elapsed_ns"] / 1e6,
                    "headstart_ms": analyzed["speculation_headstart_ns"] / 1e6,
                    "matched_stop_wait_ms": analyzed["matched_cache_stop_wait_ns"] / 1e6,
                    "mismatch_total_stop_inference_ms": analyzed[
                        "mismatch_total_stop_inference_ns"
                    ]
                    / 1e6,
                }
            )

    append_rows = [row for row in rows if row["kind"] == "append_zero"]
    eligible = [row for row in append_rows if row["endpoint_eligible"]]
    exact_acoustic = [
        row
        for row in eligible
        if not [
            field
            for field in row["canonical_vs_raw_changed"]
            if field != "audio_duration_ns"
        ]
    ]
    instant = [row for row in eligible if row["matched_stop_wait_ms"] == 0]
    peak_rss = max(
        int(run["peak_rss_bytes"])
        for runs in report["runs"].values()
        for run in runs
    )
    all_elapsed = [
        int(run["elapsed_ns"]) / 1e6
        for runs in report["runs"].values()
        for run in runs
    ]
    return {
        "path": str(path.resolve()),
        "vocabulary_enabled": report["process"]["effective_settings"][
            "vocabulary_enabled"
        ],
        "vocabulary_terms": report["process"]["effective_settings"]["vocabulary_terms"],
        "all_repeats_deterministic": report["analysis"]["all_repeats_deterministic"],
        "unique_pcm_count": len(report["runs"]),
        "run_count": sum(len(value) for value in report["runs"].values()),
        "peak_rss_bytes": peak_rss,
        "median_inference_ms": statistics.median(all_elapsed),
        "max_inference_ms": max(all_elapsed),
        "append_variant_count": len(append_rows),
        "eligible_digest_match_count": sum(
            bool(row["digest_matches"]) for row in eligible
        ),
        "eligible_count": len(eligible),
        "eligible_acoustic_parity_count": len(exact_acoustic),
        "eligible_instant_ready_count": len(instant),
        "rows": rows,
    }


def markdown(summary: dict) -> str:
    lines = [
        "# Endpoint-cache product matrix",
        "",
        f"- vocabulary enabled: `{summary['vocabulary_enabled']}` "
        f"({summary['vocabulary_terms']} terms)",
        f"- deterministic repeats: `{summary['all_repeats_deterministic']}`",
        f"- unique PCM / runs: {summary['unique_pcm_count']} / {summary['run_count']}",
        f"- process peak RSS: {summary['peak_rss_bytes'] / 1024 / 1024:.1f} MiB",
        f"- inference median / max: {summary['median_inference_ms']:.2f} / "
        f"{summary['max_inference_ms']:.2f} ms",
        f"- endpoint-eligible exact digest: {summary['eligible_digest_match_count']} / "
        f"{summary['eligible_count']}",
        f"- eligible canonical-vs-raw acoustic parity: "
        f"{summary['eligible_acoustic_parity_count']} / {summary['eligible_count']}",
        f"- eligible result already complete at stop: "
        f"{summary['eligible_instant_ready_count']} / {summary['eligible_count']}",
        "",
        "| fixture | change | eligible | digest | raw→base changed | canonical→raw changed | vocab | raw ms | cached wait ms |",
        "|---|---:|:---:|:---:|---|---|---|---:|---:|",
    ]
    for row in summary["rows"]:
        raw_changed = ", ".join(row["raw_vs_base_changed"]) or "none"
        canonical_changed = ", ".join(row["canonical_vs_raw_changed"]) or "none"
        change = (
            ("+" if row["kind"] == "append_zero" else "−")
            + f"{row['seconds']:.2f}s"
        )
        lines.append(
            f"| {row['fixture_id']} | {change} | {row['endpoint_eligible']} | "
            f"{row['digest_matches']} | {raw_changed} | {canonical_changed} | "
            f"{row['raw_vocabulary_outcome']}→{row['canonical_vocabulary_outcome']} | "
            f"{row['raw_median_ms']:.2f} | {row['matched_stop_wait_ms']:.2f} |"
        )
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("matrix", type=pathlib.Path)
    parser.add_argument("--json", type=pathlib.Path, required=True)
    parser.add_argument("--markdown", type=pathlib.Path, required=True)
    args = parser.parse_args()
    summary = summarize(args.matrix)
    args.json.write_text(
        json.dumps(summary, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    args.markdown.write_text(markdown(summary), encoding="utf-8")
    print(args.json)
    print(args.markdown)


if __name__ == "__main__":
    main()
