#!/usr/bin/env python3
"""Verify corrected armed-state semantics without touching corpus or gates."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path


ROOT = Path("$TMP/openramble-dominant-short-quality-v1")
PARENT = ROOT / "PREREGISTRATION.json"
ARMED = ROOT / "PREREGISTRATION_ARMED.json"
MANIFEST = ROOT / "final-corpus" / "manifest.json"
SEALER = ROOT / "seal_final_preregistration.py"
EVALUATOR = ROOT / "evaluate_one_shot.py"
OUTPUT = ROOT / "ARMED_VERIFICATION.json"

PARENT_SHA = "fc11882edf45b3727d124f5689a6fb179e8e7123b8437498226c00c41a5dd719"
SEALER_SHA = "2ea7fd7251dd027dcadc6f6287affe4adf384021e02f8bd14f0676b0654ac6aa"
EVALUATOR_SHA = "e0ec47123c4e31b83da0e1ebf067f9e1f1ae10488362e967739b731491b8397d"
MANIFEST_SHA = "340314c63357f2ec0bcb4091438a71b43668ecba4ad376dc8844e9785d86faf6"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def atomic_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".part")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def main() -> None:
    if OUTPUT.exists():
        raise RuntimeError("armed verification already exists")
    if sha256_file(PARENT) != PARENT_SHA:
        raise RuntimeError("blocked parent preregistration mutated")
    if sha256_file(SEALER) != SEALER_SHA:
        raise RuntimeError("corrected sealer SHA mismatch")
    if sha256_file(EVALUATOR) != EVALUATOR_SHA:
        raise RuntimeError("frozen evaluator SHA mismatch")
    if sha256_file(MANIFEST) != MANIFEST_SHA:
        raise RuntimeError("sealed corpus manifest SHA mismatch")
    parent = load(PARENT)
    armed = load(ARMED)
    if armed.get("status") != "armed_and_sealed_before_inference" or armed.get("inference_allowed") is not True:
        raise RuntimeError("armed status/permission mismatch")
    if "blocked_state" in armed.get("decision_rule", {}):
        raise RuntimeError("contradictory decision_rule.blocked_state remains")
    arming_state = armed.get("decision_rule", {}).get("arming_state", "")
    if "prerequisites are satisfied" not in arming_state or "one-shot" not in arming_state:
        raise RuntimeError("arming_state does not express satisfied/frozen protocol")
    access = armed.get("provenance_caveat", {}).get("common_voice_access", "")
    for required in ("Satisfied materialization evidence", "unofficial", "internal-evaluation-only", "must not be redistributed"):
        if required not in access:
            raise RuntimeError(f"corrected provenance caveat missing {required!r}")
    if "remains blocked" in access or "No ASR/CoreML inference is permitted" in json.dumps(armed):
        raise RuntimeError("blocked-only prose remains in corrected armed preregistration")

    # All acceptance semantics outside the explicitly corrected state/provenance
    # fields must remain exactly equal to the blocked parent template.
    for key in (
        "analysis_protocol",
        "hard_gates",
        "product_config",
        "run_protocol",
        "scope",
    ):
        if armed.get(key) != parent.get(key):
            raise RuntimeError(f"frozen preregistration field changed: {key}")
    if armed["decision_rule"].get("changes_after_arming") != parent["decision_rule"].get("changes_after_arming"):
        raise RuntimeError("changes_after_arming rule changed")
    if armed["decision_rule"].get("final") != parent["decision_rule"].get("final"):
        raise RuntimeError("final decision rule changed")
    if armed["provenance_caveat"].get("forced_derivation") != parent["provenance_caveat"].get("forced_derivation"):
        raise RuntimeError("forced-derivation policy changed")
    expected_corpus = dict(parent["corpus"])
    expected_corpus["final_manifest"] = str(MANIFEST)
    expected_corpus["final_manifest_sha256"] = MANIFEST_SHA
    if armed["corpus"] != expected_corpus:
        raise RuntimeError("armed corpus block changed outside final manifest binding")
    if armed.get("parent_blocked_preregistration_sha256") != PARENT_SHA:
        raise RuntimeError("parent preregistration binding mismatch")
    sealing = armed.get("sealing", {})
    if sealing.get("sealer_sha256") != SEALER_SHA:
        raise RuntimeError("corrected sealer binding mismatch")
    if sealing.get("template_parent_sealer_sha256") != parent["sealing"]["sealer_sha256"]:
        raise RuntimeError("parent sealer audit binding mismatch")
    if sealing.get("correction_id") != "armed-state-materialization-claim-v2":
        raise RuntimeError("sealer correction identity mismatch")

    evidence = armed.get("arming_evidence", {})
    expected_counts = {
        "compressed_source_fixture_count": 180,
        "canonical_pcm_fixture_count": 204,
        "reference_fixture_count": 204,
        "selected_pcm_overlap_count": 0,
        "model_outputs_inspected": False,
    }
    for key, expected in expected_counts.items():
        if evidence.get(key) != expected:
            raise RuntimeError(f"arming evidence count mismatch: {key}")
    artifact_pairs = (
        ("final_manifest", "final_manifest_sha256"),
        ("source_index", "source_index_sha256"),
        ("pcm_index", "pcm_index_sha256"),
        ("reference_index", "reference_index_sha256"),
        ("archive_index", "archive_index_sha256"),
        ("canonicalizer_record", "canonicalizer_record_sha256"),
        ("download_receipt", "download_receipt_sha256"),
    )
    verified_evidence = []
    for path_key, sha_key in artifact_pairs:
        path = Path(evidence.get(path_key, ""))
        actual = sha256_file(path)
        if actual != evidence.get(sha_key):
            raise RuntimeError(f"arming evidence SHA mismatch: {path_key}")
        verified_evidence.append({"path": str(path), "sha256": actual})

    verification = {
        "schema_version": 1,
        "status": "passed",
        "passed": True,
        "armed_preregistration": str(ARMED),
        "armed_preregistration_sha256": sha256_file(ARMED),
        "parent_blocked_preregistration_sha256": PARENT_SHA,
        "corrected_sealer_sha256": SEALER_SHA,
        "frozen_evaluator_sha256": EVALUATOR_SHA,
        "sealed_manifest_sha256": MANIFEST_SHA,
        "blocked_state_absent": True,
        "satisfied_arming_state_present": True,
        "unofficial_internal_only_caveat_preserved": True,
        "corpus_rows_references_pcm_evaluator_gates_product_config_changed": False,
        "arming_evidence": verified_evidence,
        "model_outputs_inspected": False,
        "asr_or_coreml_runs": 0,
    }
    atomic_json(OUTPUT, verification)
    print(json.dumps(verification, ensure_ascii=False, sort_keys=True))
    print(f"armed_verification_sha256={sha256_file(OUTPUT)}")


if __name__ == "__main__":
    main()
