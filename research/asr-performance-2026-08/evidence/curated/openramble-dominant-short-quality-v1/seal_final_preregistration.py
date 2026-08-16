#!/usr/bin/env python3
"""Arm the frozen gates only after a complete 204-row canonical manifest exists."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path


ROOT = Path("$TMP/openramble-dominant-short-quality-v1")
BLOCKED_PREREG = ROOT / "PREREGISTRATION.json"
CORE_MANIFEST = ROOT / "corpus" / "manifest.json"
SUPPLEMENT_PLAN = ROOT / "supplement-audit" / "common-voice-17" / "SELECTION_PLAN.json"
EVALUATOR = ROOT / "evaluate_one_shot.py"
ENGINEERING = Path("$TMP/openramble-short-quality-gate/corpus/manifest.json")
HOLDOUT = Path("$TMP/openramble-intermediate-quality-gate/corpus/manifest.json")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--final-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise RuntimeError("armed preregistration already exists")

    prereg = load(BLOCKED_PREREG)
    if prereg.get("status") != "blocked_pending_supplement_audio_pcm_and_final_manifest":
        raise RuntimeError("unexpected blocked preregistration status")
    if sha256_file(EVALUATOR) != prereg["analysis_protocol"]["evaluator_sha256"]:
        raise RuntimeError("frozen evaluator SHA mismatch")
    if sha256_file(SUPPLEMENT_PLAN) != prereg["corpus"]["supplement_selection_plan_sha256"]:
        raise RuntimeError("supplement selection plan SHA mismatch")
    if sha256_file(CORE_MANIFEST) != prereg["corpus"]["fleurs_core_manifest_sha256"]:
        raise RuntimeError("FLEURS core manifest SHA mismatch")

    final_manifest = load(args.final_manifest)
    if final_manifest.get("status") != "sealed_before_inference":
        raise RuntimeError("final manifest status must be sealed_before_inference")
    if final_manifest.get("inference_allowed") is not True:
        raise RuntimeError("final manifest must explicitly allow inference")
    if final_manifest.get("model_outputs_inspected") is not False:
        raise RuntimeError("final manifest must attest model_outputs_inspected=false")
    if final_manifest.get("scope") != "internal_evaluation_only_unofficial_mirror":
        raise RuntimeError("final manifest must remain internal-only/unofficial-mirror")
    if final_manifest.get("distribution_allowed") is not False:
        raise RuntimeError("final manifest must prohibit assembled-corpus distribution")
    common_voice_source = final_manifest.get("sources", {}).get("common_voice_supplement", {})
    if common_voice_source.get("mirror_is_unofficial") is not True:
        raise RuntimeError("final manifest must preserve unofficial-mirror provenance")
    if common_voice_source.get("internal_evaluation_only") is not True:
        raise RuntimeError("final manifest Common Voice source must remain internal-only")
    if common_voice_source.get("fixtures") != 180:
        raise RuntimeError("final manifest must contain exactly 180 Common Voice fixtures")
    if any(value != 0 for value in final_manifest.get("fail_closed_checks", {}).values()):
        raise RuntimeError("final manifest fail-closed counters are not all zero")
    required_artifacts = [
        (
            final_manifest.get("indices", {}).get("source"),
            final_manifest.get("indices", {}).get("source_sha256"),
            "source index",
        ),
        (
            final_manifest.get("indices", {}).get("pcm"),
            final_manifest.get("indices", {}).get("pcm_sha256"),
            "PCM index",
        ),
        (
            final_manifest.get("indices", {}).get("reference"),
            final_manifest.get("indices", {}).get("reference_sha256"),
            "reference index",
        ),
        (
            final_manifest.get("indices", {}).get("archive"),
            final_manifest.get("indices", {}).get("archive_sha256"),
            "archive index",
        ),
        (
            final_manifest.get("canonicalization", {}).get("record"),
            final_manifest.get("canonicalization", {}).get("record_sha256"),
            "canonicalizer record",
        ),
        (
            final_manifest.get("download", {}).get("receipt"),
            final_manifest.get("download", {}).get("receipt_sha256"),
            "download receipt",
        ),
    ]
    for path_value, expected_sha, role in required_artifacts:
        path = Path(path_value or "")
        if not path.is_file() or sha256_file(path) != expected_sha:
            raise RuntimeError(f"{role} missing or SHA mismatch")
    required_counts = prereg["corpus"]["required_counts"]
    if final_manifest.get("counts", {}).get("by_language_duration_bin") != required_counts:
        raise RuntimeError("final manifest does not have exact 34 x 3 x 2 balance")
    if final_manifest.get("counts", {}).get("fixtures") != 204:
        raise RuntimeError("final manifest must contain exactly 204 fixtures")
    fixtures = final_manifest.get("fixtures", [])
    if len(fixtures) != 204 or len({fixture.get("id") for fixture in fixtures}) != 204:
        raise RuntimeError("final manifest fixture IDs are missing or duplicated")

    excluded_pcm = set()
    excluded_fleurs = set()
    for path in (ENGINEERING, HOLDOUT):
        for fixture in load(path)["fixtures"]:
            if fixture.get("pcm_f32le_sha256"):
                excluded_pcm.add(fixture["pcm_f32le_sha256"])
            if fixture.get("source") == "google/fleurs":
                excluded_fleurs.add(
                    (
                        fixture.get("source_revision"),
                        fixture.get("source_config"),
                        fixture.get("source_split"),
                        int(fixture.get("source_row_index")),
                    )
                )
    core = load(CORE_MANIFEST)
    core_expected = {
        fixture["id"]: (fixture["pcm_f32le_sha256"], fixture["reference_sha256"])
        for fixture in core["fixtures"]
    }
    supplement = load(SUPPLEMENT_PLAN)
    supplement_expected = {
        (row["language"], row["split"], row["path"]): (
            row["duration_bin"],
            row["reference_sha256"],
        )
        for row in supplement["selected"]
    }
    seen_core = set()
    seen_supplement = set()
    seen_pcm = set()
    for fixture in fixtures:
        pcm_path = Path(fixture.get("pcm_path", ""))
        source_path = Path(fixture.get("source_path", ""))
        if fixture.get("sample_rate") != 16_000 or not pcm_path.is_file() or not source_path.is_file():
            raise RuntimeError(f"{fixture.get('id')}: missing canonical/source bytes or wrong sample rate")
        if sha256_file(pcm_path) != fixture.get("pcm_f32le_sha256"):
            raise RuntimeError(f"{fixture.get('id')}: PCM SHA mismatch")
        if sha256_file(source_path) != fixture.get("source_sha256"):
            raise RuntimeError(f"{fixture.get('id')}: source SHA mismatch")
        if fixture["pcm_f32le_sha256"] in excluded_pcm:
            raise RuntimeError(f"{fixture.get('id')}: prior-corpus PCM overlap")
        if fixture["pcm_f32le_sha256"] in seen_pcm:
            raise RuntimeError(f"{fixture.get('id')}: duplicate PCM within final corpus")
        seen_pcm.add(fixture["pcm_f32le_sha256"])
        if fixture.get("id") in core_expected:
            expected = core_expected[fixture["id"]]
            if (fixture.get("pcm_f32le_sha256"), fixture.get("reference_sha256")) != expected:
                raise RuntimeError(f"{fixture.get('id')}: frozen FLEURS core mutated")
            identity = (
                fixture.get("source_revision"),
                fixture.get("source_config"),
                fixture.get("source_split"),
                int(fixture.get("source_row_index")),
            )
            if identity in excluded_fleurs:
                raise RuntimeError(f"{fixture.get('id')}: prior FLEURS identity overlap")
            seen_core.add(fixture["id"])
            continue
        key = (
            fixture.get("language"),
            fixture.get("source_split"),
            fixture.get("source_filename"),
        )
        expected = supplement_expected.get(key)
        if expected is None:
            raise RuntimeError(f"{fixture.get('id')}: not in frozen Common Voice selection")
        if (fixture.get("duration_bin"), fixture.get("reference_sha256")) != expected:
            raise RuntimeError(f"{fixture.get('id')}: Common Voice duration/reference mismatch")
        if fixture.get("source_revision") != supplement["source"]["mirror_revision"]:
            raise RuntimeError(f"{fixture.get('id')}: Common Voice revision mismatch")
        if fixture.get("source_transform") in ("trim", "forced_alignment", "transcript_truncation"):
            raise RuntimeError(f"{fixture.get('id')}: forbidden derived utterance")
        seen_supplement.add(key)

    if seen_core != set(core_expected):
        raise RuntimeError("not every frozen FLEURS core fixture is present")
    if seen_supplement != set(supplement_expected):
        raise RuntimeError("not every frozen Common Voice selection is present")
    if final_manifest.get("exclusions", {}).get("selected_source_identity_overlap_count") != 0:
        raise RuntimeError("final manifest reports source identity overlap")
    if final_manifest.get("exclusions", {}).get("selected_pcm_sha256_overlap_count") != 0:
        raise RuntimeError("final manifest reports PCM overlap")

    # Deep-copy the blocked template, then replace its explicitly blocked-only
    # statements.  Leaving those strings in an inference_allowed artifact is a
    # protocol contradiction, even after the byte-level prerequisites pass.
    armed = json.loads(json.dumps(prereg, ensure_ascii=False))
    armed["status"] = "armed_and_sealed_before_inference"
    armed["inference_allowed"] = True
    armed["parent_blocked_preregistration"] = str(BLOCKED_PREREG)
    armed["parent_blocked_preregistration_sha256"] = sha256_file(BLOCKED_PREREG)
    armed["corpus"] = dict(prereg["corpus"])
    armed["corpus"]["final_manifest"] = str(args.final_manifest)
    armed["corpus"]["final_manifest_sha256"] = sha256_file(args.final_manifest)
    armed["decision_rule"].pop("blocked_state", None)
    armed["decision_rule"]["arming_state"] = (
        "The corpus-materialization prerequisites are satisfied by the exact sealed 204-row "
        "manifest and its compressed-source, canonical-PCM, reference, archive, canonicalizer, "
        "and download-receipt hashes. Inference is permitted only under the frozen one-shot "
        "protocol and separate CoreML runner coordination; partial scoring and output-driven "
        "selection remain forbidden."
    )
    armed["provenance_caveat"]["common_voice_access"] = (
        "Satisfied materialization evidence: all 180 frozen Common Voice MP3 source bytes, all "
        "180 canonical 16 kHz f32le PCM buffers, and all references are present and hash-sealed "
        "in the exact final manifest/indices. The source remains the pinned, anonymously "
        "accessible unofficial fsicoli/common_voice_17_0 mirror whose README declares CC0-1.0; "
        "these hashes attest the exact mirror bytes, not byte identity with an unavailable "
        "official archive. The assembled corpus is internal-evaluation-only and must not be "
        "redistributed."
    )
    parent_sealer_sha256 = prereg.get("sealing", {}).get("sealer_sha256")
    armed["sealing"] = dict(prereg.get("sealing", {}))
    armed["sealing"]["template_parent_sealer_sha256"] = parent_sealer_sha256
    armed["sealing"]["sealer_sha256"] = sha256_file(Path(__file__))
    armed["sealing"]["correction_id"] = "armed-state-materialization-claim-v2"
    armed["sealing"]["correction_scope"] = (
        "Replace contradictory blocked-only prose after prerequisites pass; corpus rows, "
        "references, PCM, evaluator, thresholds, normalization, and product config unchanged."
    )
    armed["arming_evidence"] = {
        "final_manifest": str(args.final_manifest),
        "final_manifest_sha256": sha256_file(args.final_manifest),
        "source_index": final_manifest["indices"]["source"],
        "source_index_sha256": final_manifest["indices"]["source_sha256"],
        "pcm_index": final_manifest["indices"]["pcm"],
        "pcm_index_sha256": final_manifest["indices"]["pcm_sha256"],
        "reference_index": final_manifest["indices"]["reference"],
        "reference_index_sha256": final_manifest["indices"]["reference_sha256"],
        "archive_index": final_manifest["indices"]["archive"],
        "archive_index_sha256": final_manifest["indices"]["archive_sha256"],
        "canonicalizer_record": final_manifest["canonicalization"]["record"],
        "canonicalizer_record_sha256": final_manifest["canonicalization"]["record_sha256"],
        "download_receipt": final_manifest["download"]["receipt"],
        "download_receipt_sha256": final_manifest["download"]["receipt_sha256"],
        "compressed_source_fixture_count": 180,
        "canonical_pcm_fixture_count": 204,
        "reference_fixture_count": 204,
        "selected_pcm_overlap_count": 0,
        "model_outputs_inspected": False,
    }
    temporary = args.output.with_suffix(args.output.suffix + ".part")
    temporary.write_text(
        json.dumps(armed, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, args.output)
    print(f"armed_preregistration={args.output}")
    print(f"armed_preregistration_sha256={sha256_file(args.output)}")


if __name__ == "__main__":
    main()
