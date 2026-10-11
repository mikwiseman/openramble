"""Paired phrase-cluster resampling of retained 200-file product measurements.

No new inference; no composite repetitions count as additional speech examples.
All source aggregate counts must reproduce before the interval analysis runs.
"""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re
import unicodedata

import jiwer
import numpy as np


def normalize(text):
    return " ".join(re.findall(r"[^\W_]+", unicodedata.normalize("NFC", text).lower().replace("ё", "е")))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bounds(values):
    return np.quantile(values, [.025, .975], method="linear").tolist()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    for name, expected in plan["inputSHA256"].items():
        assert sha(args.data / name) == expected, name
    manifest = json.loads((args.data / "manifest.json").read_text())
    fixtures = manifest["fixtures"]
    assert len(fixtures) == 200 and len({f["id"] for f in fixtures}) == 200
    published = json.loads((args.data / "products-benchmark.json").read_text())["quality"]
    products = ["openramble", "handy", "whisper", "superwhisper_turbo"]
    outputs = {p: {} for p in products}
    for line in (args.data / "observations.jsonl").read_text().splitlines():
        record = json.loads(line)
        if record["phase"] != "quality":
            continue
        product, identifier = record["engine"], record["fixture"]
        assert identifier not in outputs[product], (product, identifier)
        assert record["exit_code"] == 0 and record["valid_json"]
        outputs[product][identifier] = normalize(record["text"])
    for line in (args.data / "superwhisper-quality.jsonl").read_text().splitlines():
        record = json.loads(line)
        assert record["fixture"] not in outputs["superwhisper_turbo"]
        outputs["superwhisper_turbo"][record["fixture"]] = normalize(record["metadata"].get("rawResult", ""))
    assert all(set(rows) == {f["id"] for f in fixtures} for rows in outputs.values())
    scored = []
    for fixture in fixtures:
        reference = normalize(fixture["reference"])
        row = {"fixture": fixture["id"], "language": fixture["language"],
               "durationSeconds": fixture["duration_seconds"], "referenceWords": len(reference.split()),
               "referenceCluster": hashlib.sha256(reference.encode()).hexdigest(), "products": {}}
        for product in products:
            hypothesis = outputs[product][fixture["id"]]
            score = jiwer.process_words(reference, hypothesis)
            assert score.hits + score.substitutions + score.deletions == row["referenceWords"]
            row["products"][product] = {"substitutions": score.substitutions, "deletions": score.deletions,
                                         "insertions": score.insertions,
                                         "errors": score.substitutions + score.deletions + score.insertions,
                                         "normalizedTextSHA256": hashlib.sha256(hypothesis.encode()).hexdigest()}
        scored.append(row)
    for product in products:
        for language in ("ru", "en"):
            selected = [r for r in scored if r["language"] == language]
            expected = published[product][language]
            assert len(selected) == expected["n"] == 100
            for field in ("substitutions", "deletions", "insertions"):
                assert sum(r["products"][product][field] for r in selected) == expected[field]
            words = sum(r["referenceWords"] for r in selected)
            assert words == expected["reference_words"]
            wer = sum(r["products"][product]["errors"] for r in selected) / words
            assert abs(wer - expected["wer"]) < 1e-12
    result = {"schemaVersion": 1, "method": plan, "aggregateReproductionPassed": True,
              "normalization": "Unicode NFC, lowercase, ё→е, alphanumeric tokens, punctuation omitted; numerals not expanded",
              "languageResults": {}}
    rng = np.random.default_rng(plan["seed"])
    for language in ("ru", "en"):
        selected = [r for r in scored if r["language"] == language]
        clusters = defaultdict(list)
        for row in selected:
            clusters[row["referenceCluster"]].append(row)
        cluster_rows = [clusters[key] for key in sorted(clusters)]
        words = np.array([sum(r["referenceWords"] for r in group) for group in cluster_rows])
        errors = np.array([[sum(r["products"][p]["errors"] for r in group) for p in products] for group in cluster_rows])
        # The identical cluster draw for all products preserves pairing. Each
        # selected cluster brings all its recordings, so duplicate text is not
        # treated as a set of independent linguistic examples.
        draws = rng.integers(0, len(cluster_rows), size=(plan["replicates"], len(cluster_rows)))
        resampled_wer = errors[draws].sum(axis=1) / words[draws].sum(axis=1)[:, None]
        entry = {"recordings": len(selected), "referenceClusters": len(cluster_rows),
                 "clusterSizes": sorted(len(group) for group in cluster_rows),
                 "referenceWords": int(words.sum()), "products": {}, "pairedDifferences": {}}
        for index, product in enumerate(products):
            entry["products"][product] = {**published[product][language],
                "phraseCluster95PercentileInterval": bounds(resampled_wer[:, index]),
                "zeroErrorRecordings": sum(r["products"][product]["errors"] == 0 for r in selected)}
        for index, product in enumerate(products[1:], 1):
            differences = [r["products"]["openramble"]["errors"] - r["products"][product]["errors"] for r in selected]
            entry["pairedDifferences"][product] = {
                "direction": "OpenRamble minus comparator; negative means fewer errors for OpenRamble",
                "werDifferencePercentagePoints": (published["openramble"][language]["wer"] - published[product][language]["wer"]) * 100,
                "phraseCluster95PercentileIntervalPercentagePoints": bounds((resampled_wer[:, 0] - resampled_wer[:, index]) * 100),
                "openrambleFewerErrorsRecordings": sum(d < 0 for d in differences),
                "equalErrorCountRecordings": sum(d == 0 for d in differences),
                "openrambleMoreErrorsRecordings": sum(d > 0 for d in differences),
                "identicalNormalizedOutputRecordings": sum(outputs["openramble"][r["fixture"]] == outputs[product][r["fixture"]] for r in selected)}
        result["languageResults"][language] = entry
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "quality-uncertainty.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    (args.out / "quality-per-file.jsonl").write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in scored))
    print(json.dumps({lang: {"clusters": entry["referenceClusters"], "comparisons": entry["pairedDifferences"]}
                      for lang, entry in result["languageResults"].items()}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
