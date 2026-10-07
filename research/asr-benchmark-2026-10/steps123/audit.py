#!/usr/bin/env python3
"""Aggregate the local step 1–3 evidence without publishing transcripts."""
import argparse
from collections import Counter
import importlib.util
import json
from pathlib import Path
import re
import statistics

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("quality", ROOT / "scripts/asr-quality.py")
quality = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality)


def read_rows(path):
    # latency-benchmark prints a model-directory notice before its JSON rows.
    return [json.loads(line) for line in path.read_text().splitlines() if line.startswith("{")]


def align(reference, hypothesis):
    """Exact word alignment, same diagonal/deletion/insertion tie order as WER."""
    width = len(hypothesis) + 1
    directions = bytearray((len(reference) + 1) * width)
    previous = list(range(width))
    for j in range(1, width):
        directions[j] = 2
    for i, left in enumerate(reference, 1):
        row = [i]
        directions[i * width] = 1
        for j, right in enumerate(hypothesis, 1):
            costs = (previous[j - 1] + (left != right), previous[j] + 1, row[-1] + 1)
            direction = min(range(3), key=costs.__getitem__)
            row.append(costs[direction])
            directions[i * width + j] = direction
        previous = row
    operations = []
    i, j = len(reference), len(hypothesis)
    while i or j:
        direction = directions[i * width + j]
        if direction == 0:
            i -= 1
            j -= 1
            operations.append(("equal" if reference[i] == hypothesis[j] else "substitutions", i, j))
        elif direction == 1:
            i -= 1
            operations.append(("deletions", i, None))
        else:
            j -= 1
            operations.append(("insertions", None, j))
    operations.reverse()
    counts = Counter(op for op, _, _ in operations)
    primary = quality.edit_counts(reference, hypothesis)
    assert all(counts[key] == primary[key] for key in ("substitutions", "deletions", "insertions"))
    return operations, primary


def critical(reference, hypothesis):
    ref, hyp = quality.normalize(reference).split(), quality.normalize(hypothesis).split()
    ops, counts = align(ref, hyp)
    markers = {"не", "ни", "нельзя", "not", "never", "no"}
    run = longest = 0
    missing = []
    for op, i, _ in ops:
        run = run + 1 if op == "deletions" else 0
        longest = max(longest, run)
        if i is not None and ref[i] in markers and op != "equal":
            missing.append({"reference_index": i, "operation": op})
    return {"word_counts": counts, "longest_consecutive_deletion": longest,
            "negative_markers": sum(word in markers for word in ref),
            "negative_nonmatches": missing,
            "first_ten_match": ref[:10] == hyp[:10], "last_ten_match": ref[-10:] == hyp[-10:]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    base = args.evidence
    report = {"scope": "local execution of roadmap steps 1–3; no accepted product change",
              "timing_scope": "warm ready-PCM engine, shared desktop, not an idle lane or GUI",
              "timing": [], "quality": {}, "evidence_sha256": {}}

    def remember(path):
        report["evidence_sha256"][str(path.relative_to(base))] = quality.sha256(path)

    remember(base / "timing-plan.json")
    for index, version in enumerate(("023", "031", "031", "023")):
        path = base / f"timing-{index}-{version}.jsonl"
        rows = read_rows(path)
        assert len(rows) == 120 and len({(r["input"], r["round"]) for r in rows}) == 120
        times = [row["wallSeconds"] for row in rows]
        report["timing"].append({"process": index, "runtime": rows[0]["runtime"], "samples": len(rows),
            "p50_ms": statistics.median(times) * 1000,
            "p95_ms": quality.percentile(times, .95) * 1000,
            "peak_rss_mib": max(r["peakMemoryBytes"] for r in rows) / 2**20,
            "per_input_p50_ms": [statistics.median(r["wallSeconds"] for r in rows if r["input"] == i) * 1000
                                 for i in range(6)]})
        remember(path)

    for corpus, manifest_name in (("quick", "quick"), ("cached-e2e", "cached-e2e"),
                                  ("system-mixed", "system-mixed-rerender")):
        manifest_path = base / f"data/manifests/{manifest_name}.json"
        fixtures = quality.load_manifest(manifest_path)["fixtures"]
        producers = []
        identities = []
        for version in ("023", "031"):
            path = base / f"data/runs/{corpus}/{version}/results.jsonl"
            rows = read_rows(path)
            index = quality.indexed_results(fixtures, rows)
            rows = [index[f["id"]] for f in fixtures]
            producers.append(rows)
            identities.append(json.loads(path.with_name("identity.json").read_text()))
            remember(path)
            remember(path.with_name("identity.json"))
        old, new = producers
        for field in ("manifest_sha256", "model_sha256", "model_revision", "threads", "pipeline_binary_sha256",
                      "app_settings", "normalization", "host"):
            assert identities[0][field] == identities[1][field], field
        report["quality"][corpus] = {
            "examples": len(fixtures),
            "exact_raw_matches": sum(a.get("raw_text") == b.get("raw_text") for a, b in zip(old, new)),
            "exact_app_matches": sum(a.get("app_text") == b.get("app_text") for a, b in zip(old, new)),
            "exact_word_timing_matches": sum(a.get("words") == b.get("words") for a, b in zip(old, new)),
            "failures": [sum(r["status"] != "ok" for r in rows) for rows in producers],
            "producers": [{key: identity[key] for key in ("asr_binary_sha256", "pipeline_binary_sha256",
                                                         "model_sha256", "model_revision", "threads")}
                          for identity in identities],
            "raw_app_changed": [sum(r.get("raw_text") != r.get("app_text") for r in rows) for rows in producers],
            "frozen_pull_alias_occurrences": [sum(r.get("raw_text", "").lower().count("pull реквест") for r in rows)
                                               for rows in producers]}
        remember(manifest_path)
        if corpus == "system-mixed":
            report["long_critical"] = [critical(fixtures[0]["reference"], rows[0]["raw_text"]) for rows in producers]
            trace_path = base / "trace-mixed-batch1-023.jsonl"
            trace = read_rows(trace_path)
            assert trace[-1]["type"] == "complete"
            assert trace[-1]["text"] == old[0]["raw_text"]
            assert trace[-1]["words"] == old[0]["words"]
            report["trace"] = {"runtime": trace[-1]["runtime"], "chunks": trace[-1]["chunks"],
                               "duration": trace[-1]["duration"], "exact_shipping_result_parity": True}
            assert len(old[0]["words"]) == len(new[0]["words"])
            report["trace"]["runtime_changed_word_intervals"] = sum(a != b for a, b in zip(old[0]["words"], new[0]["words"]))
            report["trace"]["max_timestamp_delta_seconds"] = max(
                abs(a[key] - b[key]) for a, b in zip(old[0]["words"], new[0]["words"]) for key in ("start", "end"))
            report["trace"]["invalid_intervals"] = [sum(
                w["start"] < 0 or w["end"] < w["start"] or w["end"] > rows[0]["audio_seconds"]
                for w in rows[0]["words"]) for rows in producers]
            remember(trace_path)

    for name in ("short", "mixed", "long"):
        path = base / f"text-timing-{name}.jsonl"
        rows = read_rows(path)[1:]
        times = [row["seconds"] for row in rows]
        report.setdefault("text_pipeline", {})[name] = {"samples": len(rows),
            "p50_ms": statistics.median(times) * 1000, "p95_ms": quality.percentile(times, .95) * 1000}
        remember(path)
    for name in ("stop-distribution-023.log", "long-latency-attribution-023.log"):
        path = base / name
        if path.exists():
            remember(path)
    stop = re.search(r"\[stop-to-insertion\] runtime=(\S+) n=(\d+) p50=([\d.]+) p95=([\d.]+) max=([\d.]+)",
                     (base / "stop-distribution-023.log").read_text())
    assert stop
    report["controller_stop"] = {"runtime": stop[1], "samples": int(stop[2]),
        "p50_ms": float(stop[3]) * 1000, "p95_ms": float(stop[4]) * 1000,
        "max_ms": float(stop[5]) * 1000, "scope": "fixture capture and insertion; real model; not GUI"}
    for name in ("long-latency-attribution-023.log", "localasr-tests.log"):
        path = base / name
        if path.exists():
            phase_rows = []
            for line in path.read_text().splitlines():
                if not line.startswith("| "):
                    continue
                columns = line.split("|")[1:-1]
                if len(columns) != 8 or not re.search(r"\d", columns[1]):
                    continue
                values = [float(re.search(r"[\d.]+", cell)[0]) for cell in columns[1:]]
                phase_rows.append(dict(zip(("audio_seconds", "engine_seconds", "path_seconds",
                                            "pool_return_seconds", "main_return_seconds", "engine_queue_seconds",
                                            "speedup"), values)))
            report.setdefault("controller_phases", {})[name] = {"rows": phase_rows,
                "load_average_line": next((line for line in path.read_text().splitlines() if line.startswith("load ")), None)}
            remember(path)
    report["dictionary_replay"] = json.loads((base / "literal-replay-summary.json").read_text())
    for name in ("literal-replay-summary.json", "literal-replay.jsonl", "literal-controls.json",
                 "crop-provenance.json", "crop-023.jsonl"):
        remember(base / name)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
