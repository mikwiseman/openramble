#!/usr/bin/env python3
"""Read-only invariant check for the blocked dominant-short preregistration."""

from __future__ import annotations

import hashlib
import json
import subprocess
from collections import Counter
from pathlib import Path


ROOT = Path("$TMP/openramble-dominant-short-quality-v1")
REPO = Path("$REPO")
OUTPUT = ROOT / "VERIFICATION.json"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> None:
    prereg_path = ROOT / "PREREGISTRATION.json"
    manifest_path = ROOT / "corpus" / "manifest.json"
    plan_path = ROOT / "corpus" / "selection-plan.json"
    pcm_index = ROOT / "corpus" / "pcm-index.sha256"
    source_index = ROOT / "corpus" / "source-index.sha256"
    supplement_audit_path = ROOT / "supplement-audit" / "common-voice-17" / "AUDIT.json"
    supplement_plan_path = ROOT / "supplement-audit" / "common-voice-17" / "SELECTION_PLAN.json"
    evaluator_path = ROOT / "evaluate_one_shot.py"
    sealer_path = ROOT / "seal_final_preregistration.py"

    prereg = load(prereg_path)
    manifest = load(manifest_path)
    plan = load(plan_path)
    supplement_audit = load(supplement_audit_path)
    supplement_plan = load(supplement_plan_path)
    require(prereg["status"] == "blocked_pending_supplement_audio_pcm_and_final_manifest", "prereg not blocked")
    require(prereg["inference_allowed"] is False, "blocked prereg permits inference")
    require(manifest["inference_allowed"] is False, "underpowered manifest permits inference")
    require(manifest["status"] == "sealed_before_inference_underpowered_requires_pinned_supplement", "manifest status")
    require(sha256_file(manifest_path) == prereg["corpus"]["fleurs_core_manifest_sha256"], "manifest SHA")
    require(sha256_file(plan_path) == prereg["corpus"]["fleurs_core_selection_plan_sha256"], "plan SHA")
    require(sha256_file(pcm_index) == prereg["corpus"]["fleurs_core_pcm_index_sha256"], "PCM index SHA")
    require(sha256_file(source_index) == prereg["corpus"]["fleurs_core_source_index_sha256"], "source index SHA")
    require(sha256_file(supplement_audit_path) == prereg["corpus"]["supplement_audit_sha256"], "supplement audit SHA")
    require(sha256_file(supplement_plan_path) == prereg["corpus"]["supplement_selection_plan_sha256"], "supplement plan SHA")
    require(sha256_file(evaluator_path) == prereg["analysis_protocol"]["evaluator_sha256"], "evaluator SHA")
    require(sha256_file(sealer_path) == prereg["sealing"]["sealer_sha256"], "sealer SHA")
    require(sha256_file(Path(prereg["product_config"]["path"])) == prereg["product_config"]["sha256"], "product config SHA")

    fixtures = manifest["fixtures"]
    require(len(fixtures) == 24, "core fixture count")
    require(len({fixture["id"] for fixture in fixtures}) == 24, "duplicate core fixture ID")
    require(len({fixture["pcm_f32le_sha256"] for fixture in fixtures}) == 24, "duplicate core PCM")
    core_counts = Counter((fixture["language"], fixture["duration_bin"]) for fixture in fixtures)
    require(core_counts == Counter({("en", "3-4"): 12, ("ru", "3-4"): 12}), "core balance")
    for fixture in fixtures:
        pcm_path = Path(fixture["pcm_path"])
        source_path = Path(fixture["source_path"])
        require(pcm_path.is_file() and source_path.is_file(), f"{fixture['id']}: missing bytes")
        require(sha256_file(pcm_path) == fixture["pcm_f32le_sha256"], f"{fixture['id']}: PCM SHA")
        require(sha256_file(source_path) == fixture["source_sha256"], f"{fixture['id']}: source SHA")
        require(pcm_path.stat().st_size == fixture["sample_count"] * 4, f"{fixture['id']}: PCM byte count")
        require(hashlib.sha256(fixture["reference"].encode("utf-8")).hexdigest() == fixture["reference_sha256"], f"{fixture['id']}: reference SHA")
        require(3.0 <= fixture["duration_seconds"] <= 4.0, f"{fixture['id']}: duration")
    require(manifest["exclusions"]["selected_source_identity_overlap_count"] == 0, "source overlap")
    require(manifest["exclusions"]["selected_pcm_sha256_overlap_count"] == 0, "PCM overlap")
    require(plan["availability"]["eligible_en"] == 18, "FLEURS EN maximum")
    require(plan["availability"]["eligible_ru"] == 12, "FLEURS RU maximum")
    require(plan["availability"]["duration_bin_balance_possible"] is False, "FLEURS bin claim")

    require(supplement_audit["audio_downloaded"] is False, "supplement audio unexpectedly downloaded")
    require(supplement_audit["pcm_canonicalized"] is False, "supplement PCM unexpectedly exists")
    require(supplement_audit["asr_or_coreml_runs"] == 0, "supplement ASR run")
    require(supplement_audit["selection_can_fill_balanced_102_en_102_ru"] is True, "supplement shortage")
    selected = supplement_plan["selected"]
    require(len(selected) == 180, "supplement selected count")
    require(len({(row["language"], row["split"], row["path"]) for row in selected}) == 180, "supplement duplicate")
    supplement_counts = Counter((row["language"], row["duration_bin"]) for row in selected)
    expected_supplement = Counter(
        {
            ("en", "1-2"): 34,
            ("en", "2-3"): 34,
            ("en", "3-4"): 22,
            ("ru", "1-2"): 34,
            ("ru", "2-3"): 34,
            ("ru", "3-4"): 22,
        }
    )
    require(supplement_counts == expected_supplement, "supplement balance")
    require(supplement_plan["shortages"] == [], "supplement shortages")

    model_output_candidates = sorted(str(path) for path in ROOT.rglob("*.jsonl"))
    require(not model_output_candidates, "unexpected model JSONL exists")
    require(not (ROOT / "PREREGISTRATION_ARMED.json").exists(), "prereg unexpectedly armed")
    git_head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=REPO, check=True, text=True, capture_output=True
    ).stdout.strip()
    git_status = subprocess.run(
        ["git", "status", "--porcelain"], cwd=REPO, check=True, text=True, capture_output=True
    ).stdout
    require(git_status == "", "shared repository is dirty")

    result = {
        "schema_version": 1,
        "passed": True,
        "git_head": git_head,
        "shared_repository_clean": True,
        "asr_or_coreml_runs": 0,
        "model_jsonl_count": len(model_output_candidates),
        "fleurs_core": {
            "fixtures": len(fixtures),
            "counts": {"en_3_4": 12, "ru_3_4": 12},
            "eligible_pool": {"en": 18, "ru": 12},
            "source_overlap": 0,
            "pcm_overlap": 0,
        },
        "common_voice_metadata_selection": {
            "fixtures": len(selected),
            "counts": {
                "en": {"1-2": 34, "2-3": 34, "3-4": 22},
                "ru": {"1-2": 34, "2-3": 34, "3-4": 22},
            },
            "audio_downloaded": False,
            "pcm_canonicalized": False,
        },
        "artifact_hashes": {
            "preregistration": sha256_file(prereg_path),
            "fleurs_manifest": sha256_file(manifest_path),
            "fleurs_selection_plan": sha256_file(plan_path),
            "supplement_audit": sha256_file(supplement_audit_path),
            "supplement_selection_plan": sha256_file(supplement_plan_path),
            "evaluator": sha256_file(evaluator_path),
            "sealer": sha256_file(sealer_path),
        },
    }
    OUTPUT.write_text(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
