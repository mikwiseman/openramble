#!/usr/bin/env python3
"""Seal the final CPU-only checkpoint and non-self-referential artifact index."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path


ROOT = Path("$TMP/openramble-dominant-short-quality-v1")
INDEX = ROOT / "FINAL_ARTIFACT_INDEX.json"
CHECKPOINT = ROOT / "CPU_CHECKPOINT.json"


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


def artifact(path: Path, role: str) -> dict:
    if not path.is_file():
        raise RuntimeError(f"missing artifact: {path}")
    return {
        "path": str(path),
        "role": role,
        "size": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def main() -> None:
    if INDEX.exists() or CHECKPOINT.exists():
        raise RuntimeError("final CPU checkpoint already exists")
    manifest_path = ROOT / "final-corpus" / "manifest.json"
    verification_path = ROOT / "FINAL_VERIFICATION.json"
    negative_path = ROOT / "NEGATIVE_SEALER_TESTS.json"
    armed_verification_path = ROOT / "ARMED_VERIFICATION.json"
    armed_path = ROOT / "PREREGISTRATION_ARMED.json"
    manifest = load(manifest_path)
    verification = load(verification_path)
    negative = load(negative_path)
    armed_verification = load(armed_verification_path)
    armed = load(armed_path)
    if not verification.get("passed") or not negative.get("passed") or not armed_verification.get("passed"):
        raise RuntimeError("corpus/negative/armed verification is not green")
    if armed.get("status") != "armed_and_sealed_before_inference":
        raise RuntimeError("frozen sealer did not arm preregistration")
    if armed["corpus"]["final_manifest_sha256"] != sha256_file(manifest_path):
        raise RuntimeError("armed preregistration manifest SHA mismatch")

    artifact_specs = [
        (ROOT / "corpus" / "manifest.json", "frozen FLEURS 24-row core manifest"),
        (ROOT / "corpus" / "pcm-index.sha256", "FLEURS core PCM index"),
        (ROOT / "corpus" / "source-index.sha256", "FLEURS core source index"),
        (ROOT / "supplement-audit" / "common-voice-17" / "README.md", "pinned unofficial mirror license/readme evidence"),
        (ROOT / "supplement-audit" / "common-voice-17" / "AUDIT.json", "frozen metadata-only supplement audit"),
        (ROOT / "supplement-audit" / "common-voice-17" / "SELECTION_PLAN.json", "frozen 180-row supplement selection"),
        (ROOT / "PREREGISTRATION.json", "frozen blocked preregistration"),
        (ROOT / "evaluate_one_shot.py", "frozen one-shot evaluator"),
        (ROOT / "seal_final_preregistration.py", "frozen final-manifest sealer"),
        (ROOT / "prepare_common_voice_final.py", "pinned sparse-fetch and canonicalization preparer"),
        (ROOT / "verify_final_corpus.py", "independent final corpus verifier"),
        (ROOT / "verify_armed_preregistration.py", "independent corrected armed-state verifier"),
        (ROOT / "run_negative_sealer_tests.py", "adversarial frozen-sealer test driver"),
        (ROOT / "final-corpus" / "manifest.json", "sealed exact 204-row final corpus manifest"),
        (ROOT / "final-corpus" / "source-index.sha256", "204-row compressed-source hash index"),
        (ROOT / "final-corpus" / "pcm-index.sha256", "204-row canonical PCM hash index"),
        (ROOT / "final-corpus" / "reference-index.sha256", "204-row reference hash index"),
        (ROOT / "final-corpus" / "archive-index.json", "pinned TAR provenance and header-chain index"),
        (ROOT / "final-corpus" / "download-receipt.json", "exact sparse network byte accounting"),
        (ROOT / "final-corpus" / "canonicalizer.json", "afconvert canonicalizer provenance"),
        (ROOT / "FINAL_VERIFICATION.json", "independent positive verification receipt"),
        (ROOT / "ARMED_VERIFICATION.json", "independent corrected armed-state receipt"),
        (ROOT / "NEGATIVE_SEALER_TESTS.json", "five-case fail-closed verification receipt"),
        (ROOT / "PREREGISTRATION_ARMED.json", "armed immutable preregistration"),
        (ROOT / "sealer-final.stdout", "frozen sealer success stdout"),
        (ROOT / "sealer-final.stderr", "frozen sealer success stderr"),
    ]
    artifacts = [artifact(path, role) for path, role in artifact_specs]
    index = {
        "schema_version": 1,
        "status": "sealed",
        "root": str(ROOT),
        "artifact_count": len(artifacts),
        "artifacts": artifacts,
        "individual_source_pcm_reference_hashes": (
            "sealed manifest plus its source/PCM/reference indices; source and PCM files are not duplicated here"
        ),
    }
    atomic_json(INDEX, index)

    common_fixtures = [
        fixture for fixture in manifest["fixtures"] if fixture.get("mirror_is_unofficial") is True
    ]
    core_fixtures = [
        fixture for fixture in manifest["fixtures"] if fixture.get("mirror_is_unofficial") is not True
    ]
    source_bytes = sum(Path(fixture["source_path"]).stat().st_size for fixture in common_fixtures)
    common_pcm_bytes = sum(Path(fixture["pcm_path"]).stat().st_size for fixture in common_fixtures)
    all_pcm_bytes = sum(Path(fixture["pcm_path"]).stat().st_size for fixture in manifest["fixtures"])
    jsonl_outputs = sorted(str(path) for path in ROOT.rglob("*.jsonl"))
    if jsonl_outputs:
        raise RuntimeError(f"unexpected model output JSONLs: {jsonl_outputs}")
    repo = Path("$REPO")
    git_status = subprocess.run(
        ["git", "status", "--short"], cwd=repo, check=True, text=True, capture_output=True
    ).stdout
    if git_status:
        raise RuntimeError("shared repo is not clean")
    git_head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, check=True, text=True, capture_output=True
    ).stdout.strip()

    checkpoint = {
        "schema_version": 1,
        "status": "frozen_cpu_only_ready_for_separately_coordinated_inference",
        "scope": "internal_evaluation_only_unofficial_mirror",
        "distribution_allowed": False,
        "warning": (
            "The Common Voice source is a pinned unofficial mirror declaring CC0-1.0. "
            "Keep the assembled corpus internal; do not redistribute it."
        ),
        "corpus": {
            "manifest": str(manifest_path),
            "manifest_sha256": sha256_file(manifest_path),
            "fixtures": len(manifest["fixtures"]),
            "fleurs_core": len(core_fixtures),
            "common_voice_supplement": len(common_fixtures),
            "en": manifest["counts"]["en"],
            "ru": manifest["counts"]["ru"],
            "by_language_duration_bin": manifest["counts"]["by_language_duration_bin"],
            "unique_fixture_ids": manifest["counts"]["unique_fixture_ids"],
            "unique_compressed_source_sha256": manifest["counts"]["unique_common_voice_source_sha256"],
            "unique_pcm_sha256": manifest["counts"]["unique_pcm_sha256"],
        },
        "source": {
            "upstream_release": "Mozilla Common Voice Corpus 17.0",
            "license_declared_by_mirror": "CC0-1.0",
            "mirror_repository": "fsicoli/common_voice_17_0",
            "mirror_revision": "8262c16bf297c87a9cd88c51997c4758ed7a8ba2",
            "mirror_is_unofficial": True,
            "readme_sha256": "5d7f13a790c3f4de73ec28608570d7a4619bce675f37bdd42af47dfa6bfb0281",
            "selected_compressed_file_count": len(common_fixtures),
            "selected_compressed_bytes": source_bytes,
            "every_compressed_sha_recomputed": True,
        },
        "canonical_pcm": {
            "format": "mono 16000-Hz IEEE-754 Float32 little-endian",
            "transform": "complete utterance decode/resample only; no trim/alignment/VAD/transcript change",
            "common_voice_bytes": common_pcm_bytes,
            "all_204_bytes": all_pcm_bytes,
            "every_pcm_sha_recomputed": True,
            "maximum_declared_duration_delta_seconds": verification["duration_delta_seconds"]["maximum_absolute"],
        },
        "download": manifest["download"],
        "verification": {
            "receipt": str(verification_path),
            "receipt_sha256": sha256_file(verification_path),
            "passed": True,
            "negative_tests": str(negative_path),
            "negative_tests_sha256": sha256_file(negative_path),
            "negative_cases_passed": negative["cases_passed"],
            "armed_verification": str(armed_verification_path),
            "armed_verification_sha256": sha256_file(armed_verification_path),
            "armed_state_contradiction_absent": True,
            "missing_duplicate_hash_locale_bin_overlap_failures": 0,
        },
        "preregistration": {
            "blocked_parent": str(ROOT / "PREREGISTRATION.json"),
            "blocked_parent_sha256": sha256_file(ROOT / "PREREGISTRATION.json"),
            "armed": str(armed_path),
            "armed_sha256": sha256_file(armed_path),
            "evaluator": str(ROOT / "evaluate_one_shot.py"),
            "evaluator_sha256": sha256_file(ROOT / "evaluate_one_shot.py"),
            "selection_plan_sha256": sha256_file(
                ROOT / "supplement-audit" / "common-voice-17" / "SELECTION_PLAN.json"
            ),
            "model_outputs_inspected": False,
        },
        "artifact_index": str(INDEX),
        "artifact_index_sha256": sha256_file(INDEX),
        "asr_or_coreml_runs": 0,
        "model_output_jsonl_count": len(jsonl_outputs),
        "shared_repo_head": git_head,
        "shared_repo_clean": True,
    }
    atomic_json(CHECKPOINT, checkpoint)
    print(json.dumps(checkpoint, ensure_ascii=False, sort_keys=True))
    print(f"artifact_index_sha256={sha256_file(INDEX)}")
    print(f"cpu_checkpoint_sha256={sha256_file(CHECKPOINT)}")


if __name__ == "__main__":
    main()
