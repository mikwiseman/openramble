#!/usr/bin/env python3
import difflib
import hashlib
import json
import math
import statistics
import sys
from pathlib import Path


def file_sha256(file_path: Path) -> str:
    digest = hashlib.sha256()
    with file_path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def normalize(text: str) -> str:
    return " ".join(
        "".join(character.lower() if character.isalnum() else " " for character in text).split()
    )


def edit_distance(reference_words, hypothesis_words):
    previous = list(range(len(hypothesis_words) + 1))
    for reference_index, reference_word in enumerate(reference_words, 1):
        current = [reference_index]
        for hypothesis_index, hypothesis_word in enumerate(hypothesis_words, 1):
            substitution = previous[hypothesis_index - 1] + (reference_word != hypothesis_word)
            insertion = current[hypothesis_index - 1] + 1
            deletion = previous[hypothesis_index] + 1
            current.append(min(substitution, insertion, deletion))
        previous = current
    return previous[-1]


def wer(reference: str, hypothesis: str):
    reference_words = normalize(reference).split()
    hypothesis_words = normalize(hypothesis).split()
    if not reference_words:
        return None
    edits = edit_distance(reference_words, hypothesis_words)
    return {
        "edits": edits,
        "reference_words": len(reference_words),
        "hypothesis_words": len(hypothesis_words),
        "wer": edits / len(reference_words),
    }


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return float(ordered[lower])
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def word_diff(reference: str, hypothesis: str):
    reference_words = normalize(reference).split()
    hypothesis_words = normalize(hypothesis).split()
    matcher = difflib.SequenceMatcher(a=reference_words, b=hypothesis_words, autojunk=False)
    return [
        {
            "operation": tag,
            "shipping_words": reference_words[left_start:left_end],
            "short_words": hypothesis_words[right_start:right_end],
        }
        for tag, left_start, left_end, right_start, right_end in matcher.get_opcodes()
        if tag != "equal"
    ]


def words_at(words, center, radius=0.1):
    lower = center - radius
    upper = center + radius
    return [
        {
            "word": word["word"],
            "startTime": word["startTime"],
            "endTime": word["endTime"],
        }
        for word in words
        if word["endTime"] >= lower and word["startTime"] <= upper
    ]


def timing_alignment_summary(shipping_words, short_words):
    shipping_normalized = [normalize(item["word"]) for item in shipping_words]
    short_normalized = [normalize(item["word"]) for item in short_words]
    matcher = difflib.SequenceMatcher(
        a=shipping_normalized, b=short_normalized, autojunk=False
    )
    pairs = []
    for block in matcher.get_matching_blocks():
        for offset in range(block.size):
            left = shipping_words[block.a + offset]
            right = short_words[block.b + offset]
            pairs.append(
                {
                    "word": shipping_normalized[block.a + offset],
                    "shippingStartTime": left["startTime"],
                    "shortStartTime": right["startTime"],
                    "startDeltaSeconds": right["startTime"] - left["startTime"],
                    "shippingEndTime": left["endTime"],
                    "shortEndTime": right["endTime"],
                    "endDeltaSeconds": right["endTime"] - left["endTime"],
                }
            )
    start_absolute = [abs(pair["startDeltaSeconds"]) for pair in pairs]
    end_absolute = [abs(pair["endDeltaSeconds"]) for pair in pairs]
    return {
        "shippingWordCount": len(shipping_words),
        "shortWordCount": len(short_words),
        "matchedWordCount": len(pairs),
        "maximumAbsoluteStartDeltaSeconds": max(start_absolute) if pairs else None,
        "medianAbsoluteStartDeltaSeconds": (
            statistics.median(start_absolute) if pairs else None
        ),
        "maximumAbsoluteEndDeltaSeconds": max(end_absolute) if pairs else None,
        "medianAbsoluteEndDeltaSeconds": (
            statistics.median(end_absolute) if pairs else None
        ),
    }


def seam_contexts(shipping_fixture, short_fixture):
    layouts = short_fixture["firstWindowLayouts"]
    contexts = []
    for transition in range(1, len(layouts)):
        previous_layout = layouts[transition - 1]
        current_layout = layouts[transition]
        overlap_start = current_layout["visibleStartSample"] / 16_000
        overlap_end = previous_layout["visibleEndSample"] / 16_000
        geometric_midpoint = (overlap_start + overlap_end) / 2
        contexts.append(
            {
                "transition": transition,
                "overlapStartSeconds": overlap_start,
                "overlapEndSeconds": overlap_end,
                "actualOverlapSeconds": overlap_end - overlap_start,
                "geometricOverlapMidpointSeconds": geometric_midpoint,
                "radiusSeconds": 0.1,
                "shippingWords": words_at(
                    shipping_fixture["firstWordTimings"], geometric_midpoint
                ),
                "shortWords": words_at(
                    short_fixture["firstWordTimings"], geometric_midpoint
                ),
                "note": (
                    "The current merge first tries time-tolerant contiguous/LCS token matching. "
                    "This is the geometric midpoint of the captured audio overlap, not proof "
                    "of the actual token-match splice; midpoint fallback itself uses emitted "
                    "token-stream bounds."
                ),
            }
        )
    return contexts


def main():
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: analyze_universal_smoke.py shipping.json short.json golden.json output.json"
        )
    shipping_path, short_path, golden_path, output_path = map(Path, sys.argv[1:])
    shipping = json.loads(shipping_path.read_text())
    short = json.loads(short_path.read_text())
    golden = json.loads(golden_path.read_text())
    golden_texts = golden["texts"]
    shipping_by_id = {fixture["id"]: fixture for fixture in shipping["fixtures"]}
    short_by_id = {fixture["id"]: fixture for fixture in short["fixtures"]}

    reference_by_id = {
        "real-en-product-names-56.104s": golden_texts["samples/product-names.wav"],
        "real-en-whole-earth-84.381s": golden_texts["samples/whole-earth.wav"],
    }
    fixture_results = []
    material_failures = []
    for fixture_id, shipping_fixture in shipping_by_id.items():
        short_fixture = short_by_id[fixture_id]
        exact_equal = (
            shipping_fixture["firstMeasuredTranscriptSHA256"]
            == short_fixture["firstMeasuredTranscriptSHA256"]
        )
        normalized_equal = (
            shipping_fixture["firstMeasuredNormalizedTranscriptSHA256"]
            == short_fixture["firstMeasuredNormalizedTranscriptSHA256"]
        )
        pair_wer = wer(
            shipping_fixture["firstMeasuredTranscript"],
            short_fixture["firstMeasuredTranscript"],
        )
        reference = reference_by_id.get(fixture_id)
        shipping_reference_wer = (
            wer(reference, shipping_fixture["firstMeasuredTranscript"]) if reference else None
        )
        short_reference_wer = (
            wer(reference, short_fixture["firstMeasuredTranscript"]) if reference else None
        )
        result = {
            "id": fixture_id,
            "durationSeconds": shipping_fixture["audioDurationSeconds"],
            "sourceSHA256": shipping_fixture["sourceSHA256"],
            "exactTranscriptEqual": exact_equal,
            "normalizedTranscriptEqual": normalized_equal,
            "shippingTranscript": shipping_fixture["firstMeasuredTranscript"],
            "shortTranscript": short_fixture["firstMeasuredTranscript"],
            "shippingTranscriptSHA256": shipping_fixture[
                "firstMeasuredTranscriptSHA256"
            ],
            "shortTranscriptSHA256": short_fixture["firstMeasuredTranscriptSHA256"],
            "shippingNormalizedTranscriptSHA256": shipping_fixture[
                "firstMeasuredNormalizedTranscriptSHA256"
            ],
            "shortNormalizedTranscriptSHA256": short_fixture[
                "firstMeasuredNormalizedTranscriptSHA256"
            ],
            "shippingVsShortWER": pair_wer,
            "wordDiff": word_diff(
                shipping_fixture["firstMeasuredTranscript"],
                short_fixture["firstMeasuredTranscript"],
            ),
            "frozenReference": reference,
            "frozenReferenceProvenance": (
                "transcribe.cpp tests/golden/batch/parakeet-tdt-0.6b-v2.cpu.json; "
                "frozen ASR golden, not an independently human-verified transcript"
                if reference
                else None
            ),
            "shippingWERAgainstFrozenReference": shipping_reference_wer,
            "shortWERAgainstFrozenReference": short_reference_wer,
            "shippingEncoderWindows": shipping_fixture["encoderWindowCounts"],
            "shortEncoderWindows": short_fixture["encoderWindowCounts"],
            "shippingWarmSmokeLatencyNanoseconds": shipping_fixture[
                "elapsedNanoseconds"
            ],
            "shortWarmSmokeLatencyNanoseconds": short_fixture["elapsedNanoseconds"],
            "shippingWarmSmokeP50Nanoseconds": statistics.median(
                shipping_fixture["elapsedNanoseconds"]
            ),
            "shortWarmSmokeP50Nanoseconds": statistics.median(
                short_fixture["elapsedNanoseconds"]
            ),
            "shippingWarmSmokeP95Nanoseconds": percentile(
                shipping_fixture["elapsedNanoseconds"], 0.95
            ),
            "shortWarmSmokeP95Nanoseconds": percentile(
                short_fixture["elapsedNanoseconds"], 0.95
            ),
            "latencyCaveat": "smoke n=2 only; acceptance n>=30 intentionally not run after hard stop",
            "shippingTranscriptStable": shipping_fixture["transcriptStable"],
            "shortTranscriptStable": short_fixture["transcriptStable"],
            "shippingTokenTimingStable": shipping_fixture["tokenTimingsStable"],
            "shortTokenTimingStable": short_fixture["tokenTimingsStable"],
            "shippingWordTimingStable": shipping_fixture["wordTimingsStable"],
            "shortWordTimingStable": short_fixture["wordTimingsStable"],
            "shippingTokenTimingHashVariants": shipping_fixture[
                "tokenTimingHashVariants"
            ],
            "shortTokenTimingHashVariants": short_fixture["tokenTimingHashVariants"],
            "shippingWordTimingHashVariants": shipping_fixture[
                "wordTimingHashVariants"
            ],
            "shortWordTimingHashVariants": short_fixture["wordTimingHashVariants"],
            "shippingWordCount": len(shipping_fixture["firstWordTimings"]),
            "shortWordCount": len(short_fixture["firstWordTimings"]),
            "alignedWordTimingSummary": timing_alignment_summary(
                shipping_fixture["firstWordTimings"],
                short_fixture["firstWordTimings"],
            ),
            "shortSeamContexts": seam_contexts(shipping_fixture, short_fixture),
        }
        fixture_results.append(result)
        if pair_wer and pair_wer["wer"] >= 0.05:
            material_failures.append(
                {
                    "id": fixture_id,
                    "reason": "shipping-vs-short normalized WER >= 5%",
                    "wer": pair_wer["wer"],
                    "wordDiff": result["wordDiff"],
                }
            )
        if (
            shipping_reference_wer
            and short_reference_wer
            and short_reference_wer["wer"] - shipping_reference_wer["wer"] >= 0.02
        ):
            material_failures.append(
                {
                    "id": fixture_id,
                    "reason": "short frozen-reference WER degraded by >= 2 percentage points",
                    "shippingWER": shipping_reference_wer["wer"],
                    "shortWER": short_reference_wer["wer"],
                }
            )

    analysis = {
        "schemaVersion": 1,
        "decision": "HARD_STOP_MATERIAL_PARITY_FAILURE",
        "acceptanceN30Run": False,
        "materialFailures": material_failures,
        "shippingReportSHA256": file_sha256(shipping_path),
        "shortReportSHA256": file_sha256(short_path),
        "goldenReferenceSHA256": file_sha256(golden_path),
        "shippingProcess": {
            key: shipping[key]
            for key in (
                "modelsLoadNanoseconds",
                "managerLoadNanoseconds",
                "firstInferenceNanoseconds",
                "peakRSSAtStartBytes",
                "peakRSSAfterModelsLoadBytes",
                "peakRSSAfterManagerLoadBytes",
                "peakRSSAfterFirstInferenceBytes",
                "peakRSSAtEndBytes",
            )
        },
        "shortProcess": {
            key: short[key]
            for key in (
                "modelsLoadNanoseconds",
                "managerLoadNanoseconds",
                "firstInferenceNanoseconds",
                "peakRSSAtStartBytes",
                "peakRSSAfterModelsLoadBytes",
                "peakRSSAfterManagerLoadBytes",
                "peakRSSAfterFirstInferenceBytes",
                "peakRSSAtEndBytes",
            )
        },
        "shippingChunkPolicy": shipping["chunkPolicy"],
        "shortChunkPolicy": short["chunkPolicy"],
        "fixtures": fixture_results,
    }
    output_path.write_text(json.dumps(analysis, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
