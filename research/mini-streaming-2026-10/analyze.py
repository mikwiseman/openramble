"""Score successful public-fixture runs. Repeats are not new quality samples."""
import argparse
from collections import defaultdict
import gzip
import hashlib
import json
from pathlib import Path
import re
import statistics
import unicodedata

import jiwer


def normalized(text):
    return " ".join(re.findall(r"[^\W_]+", unicodedata.normalize("NFC", text).lower().replace("ё", "е")))


def quantile(values, p):
    values = sorted(values)
    position = (len(values) - 1) * p
    index = int(position)
    return values[index] + (values[min(index + 1, len(values) - 1)] - values[index]) * (position - index)


def stats(values):
    return {"n": len(values), "p50": quantile(values, .5), "p95": quantile(values, .95),
            "min": min(values), "max": max(values)}


def score(reference, text):
    result = jiwer.process_words(normalized(reference), normalized(text))
    n = len(result.references[0])
    gaps = []
    for alignment in result.alignments[0]:
        if alignment.type == "delete":
            a, b = alignment.ref_start_idx, alignment.ref_end_idx
            if b - a >= 4:
                gaps.append({"startWord": a, "endWord": b, "text": " ".join(result.references[0][a:b])})
    return {"wer": result.wer, "deletionRate": result.deletions / n, "referenceWords": n,
            "substitutions": result.substitutions, "deletions": result.deletions, "insertions": result.insertions,
            "deletionRunsAtLeastFourWords": gaps}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--failure-runs", nargs="*", type=Path, default=[])
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((args.data / "mini-inputs.json").read_text())
    fixtures = {f["id"]: f for f in manifest["fixtures"]}
    rows, observations, identities, failures = [], [], {}, []
    seen = set()
    for run in args.failure_runs:
        for line in (run / "observations.jsonl").read_text().splitlines():
            observation = json.loads(line)
            if observation.get("exit_code") != 0 or "hard_stop" in observation:
                failures.append({"run": run.name, "id": observation["id"],
                                 "exitCode": observation["exit_code"], "hardStop": observation.get("hard_stop"),
                                 "samples": observation["pressure"],
                                 "identity": json.loads((run / "identity.json").read_text())})
    for run in args.runs:
        identities[run.name] = json.loads((run / "identity.json").read_text())
        for line in (run / "observations.jsonl").read_text().splitlines():
            observation = json.loads(line)
            key = (run.name, observation["id"])
            path = run / "raw" / (observation["id"] + ".json")
            if observation["exit_code"] != 0 or "hard_stop" in observation or not path.exists():
                failures.append({"run": run.name, "id": observation["id"], "exitCode": observation["exit_code"],
                                 "hardStop": observation.get("hard_stop"), "samples": observation["pressure"],
                                 "utc": observation["before"]["utc"], "identity": identities[run.name]})
                continue
            if key in seen:
                raise ValueError(f"duplicate completed run: {key}")
            seen.add(key)
            raw = json.loads(path.read_text())
            row = {**raw, "run": run.name, "fixture": observation["fixture"],
                   "condition": observation["condition"], "repeat": observation["repeat"]}
            row["quality"] = score(fixtures[row["fixture"]]["reference"], row["text"])
            row["normalizedTextSHA256"] = hashlib.sha256(normalized(row["text"]).encode()).hexdigest()
            memory = [p["memory"]["physicalFootprintBytes"] for p in observation["pressure"] if p.get("memory")]
            row["sampledPeakPhysicalFootprintBytes"] = max(memory) if memory else None
            rows.append(row)
            # Keep full snapshots privately. Publish only system-level values.
            clean = {k: observation[k] for k in ("id", "fixture", "condition", "repeat", "exit_code", "process_seconds", "pressure")}
            for stage in ("before", "under_condition", "after"):
                clean[stage] = {k: v for k, v in observation[stage].items() if k != "processes"}
            observations.append(clean)

    groups = defaultdict(list)
    for row in rows:
        key = (row["mode"], row["fixture"], row["pacing"], row["workers"], row["condition"])
        groups[key].append(row)
    summaries = []
    for key, members in sorted(groups.items()):
        mode, fixture, pacing, workers, condition = key
        field = "stopSeconds" if mode in ("controller", "meeting") else "processingSeconds"
        summary = dict(mode=mode, fixture=fixture, pacing=pacing, workers=workers, condition=condition,
                       seconds=stats([r[field] for r in members]),
                       audioSeconds=members[0]["audioSeconds"],
                       peakRSSBytes=max(r["peakRSSBytes"] for r in members),
                       loadSeconds=stats([r["loadSeconds"] for r in members]),
                       sampledPeakPhysicalFootprintBytes=max((r["sampledPeakPhysicalFootprintBytes"] or 0) for r in members),
                       wer=stats([r["quality"]["wer"] for r in members]),
                       deletionRate=stats([r["quality"]["deletionRate"] for r in members]),
                       referenceWords=members[0]["quality"]["referenceWords"],
                       distinctNormalizedOutputs=len({r["normalizedTextSHA256"] for r in members}),
                       ids=[r["id"] for r in members])
        if mode == "controller":
            summary.update(cuts=sorted({r["cuts"] for r in members}),
                           completedBeforeStop=sorted({r["completedBeforeStop"] for r in members}),
                           maxFeedLatenessSeconds=max(r["maxFeedLatenessSeconds"] for r in members),
                           fileBacked=all(r["fileBacked"] for r in members))
        summaries.append(summary)

    parity = []
    for fixture in sorted({r["fixture"] for r in rows if r["mode"] == "file"}):
        candidates = [r for r in rows if r["mode"] == "file" and r["fixture"] == fixture]
        base = next(r for r in candidates if r["workers"] == 1)
        def chunks(r):
            return [(c["index"], c["startFrame"], c["boundaryFrame"], c["endFrame"], c["textSHA256"]) for c in r["chunks"]]
        for row in candidates + [r for r in rows if r["mode"] == "shipping-file" and r["fixture"] == fixture]:
            parity.append({"fixture": fixture, "id": row["id"], "baseline": base["id"],
                           "exactText": row["text"] == base["text"],
                           "normalizedText": row["normalizedTextSHA256"] == base["normalizedTextSHA256"],
                           "exactWordTimings": row["words"] == base["words"],
                           "validWordTimings": row["timingBoundsValid"],
                           "chunkCount": len(row["chunks"]),
                           "chunkBoundariesAndText": chunks(row) == chunks(base) if row["mode"] == "file" else None})

    result = {"normalization": "Unicode NFC, lowercase, ё→е, Unicode word tokens, no numeral expansion",
              "quantiles": "linear interpolation at (n-1)*p", "qualityScope": "Fixed public fixtures; timing repeats are not independent quality examples.",
              "identities": identities, "completedRuns": len(rows), "failures": failures, "groups": summaries, "fileParity": parity}
    (args.out / "summary.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    # Gzip stores no timestamp or local filename. No audio or private paths.
    for name, values in (("public-runs.jsonl.gz", rows), ("system-observations.jsonl.gz", observations)):
        with (args.out / name).open("wb") as target:
            with gzip.GzipFile(fileobj=target, mode="wb", mtime=0, filename="") as stream:
                for value in values:
                    stream.write((json.dumps(value, ensure_ascii=False) + "\n").encode())
    public_manifest = {**manifest, "fixtures": [{k: v for k, v in f.items() if k != "path"} for f in fixtures.values()]}
    (args.out / "fixtures.json").write_text(json.dumps(public_manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"completedRuns": len(rows), "groups": len(summaries), "failures": failures}, ensure_ascii=False))


if __name__ == "__main__":
    main()
