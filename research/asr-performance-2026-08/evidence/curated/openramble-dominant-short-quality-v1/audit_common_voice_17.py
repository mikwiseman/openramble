#!/usr/bin/env python3
"""Metadata-only audit of a pinned Common Voice 17 mirror; never decodes audio."""

from __future__ import annotations

import csv
import hashlib
import json
import os
from collections import Counter
from pathlib import Path


ROOT = Path("$TMP/openramble-dominant-short-quality-v1")
AUDIT_ROOT = ROOT / "supplement-audit" / "common-voice-17"
META = AUDIT_ROOT / "meta"
OUTPUT = AUDIT_ROOT / "AUDIT.json"
SELECTION = AUDIT_ROOT / "SELECTION_PLAN.json"
CORE_MANIFEST = ROOT / "corpus" / "manifest.json"

REPOSITORY = "fsicoli/common_voice_17_0"
REVISION = "8262c16bf297c87a9cd88c51997c4758ed7a8ba2"
RELEASE = "Mozilla Common Voice Corpus 17.0"
LICENSE = "CC0-1.0"
SEED = "openramble-dominant-short-common-voice-17-supplement-v1-20260814"
FINAL_PER_BIN = 34
CORE_PER_BIN = {"1-2": 0, "2-3": 0, "3-4": 12}

EXPECTED_SHA = {
    "en-clip_durations.tsv": "693987b4fe15a6c90733639466509474f80da95d4413f123be9cf45ff41200a6",
    "en-dev.tsv": "d2fae3f98cbf44c7c47d6cc94449e2b6b68400c2048d73a19cb645b5df642236",
    "en-test.tsv": "b4d4db369413fcacacebee7de48e94c96c4f63383d6582e18a9b0856c5c8461a",
    "ru-clip_durations.tsv": "5892cb96e5a9ad4318f91b363fab7b84435577449d6bed8cfbb1a9f7d31bf735",
    "ru-dev.tsv": "e031512f0c4e18799ec6c0472552b697b069c5fc905317e0a5de9394458b81a1",
    "ru-test.tsv": "15162124bd657adea07695c22508b8bad174c282dcafe2302faaed05645cc59a",
    "README.md": "5d7f13a790c3f4de73ec28608570d7a4619bce675f37bdd42af47dfa6bfb0281",
}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".part")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def duration_bin(duration_ms: int) -> str | None:
    if 1_000 <= duration_ms < 2_000:
        return "1-2"
    if 2_000 <= duration_ms < 3_000:
        return "2-3"
    if 3_000 <= duration_ms <= 4_000:
        return "3-4"
    return None


def verify_inputs() -> list[dict]:
    artifacts = []
    for filename, expected in sorted(EXPECTED_SHA.items()):
        path = AUDIT_ROOT / filename if filename == "README.md" else META / filename
        actual = sha256_file(path)
        if actual != expected:
            raise RuntimeError(f"{path}: SHA {actual} != {expected}")
        artifacts.append(
            {
                "path": str(path),
                "sha256": actual,
                "size": path.stat().st_size,
            }
        )
    return artifacts


def read_split(language: str, split: str) -> list[dict]:
    path = META / f"{language}-{split}.tsv"
    rows = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t", quoting=csv.QUOTE_NONE)
        required = {"client_id", "path", "sentence_id", "sentence", "locale"}
        if not required.issubset(reader.fieldnames or []):
            raise RuntimeError(f"{path}: missing required columns")
        for row_index, row in enumerate(reader):
            if row["locale"] != language:
                raise RuntimeError(f"{path}:{row_index + 2}: locale mismatch")
            if not row["path"].endswith(".mp3") or not row["sentence"].strip():
                raise RuntimeError(f"{path}:{row_index + 2}: invalid path/reference")
            rows.append(
                {
                    "language": language,
                    "split": split,
                    "source_row_index": row_index,
                    "path": row["path"],
                    "sentence_id": row["sentence_id"],
                    "reference": row["sentence"],
                    "reference_sha256": sha256_bytes(row["sentence"].encode("utf-8")),
                    "client_id_sha256": sha256_bytes(row["client_id"].encode("utf-8")),
                    "up_votes": int(row["up_votes"] or 0),
                    "down_votes": int(row["down_votes"] or 0),
                    "age": row.get("age", ""),
                    "gender": row.get("gender", ""),
                    "accent": row.get("accents", ""),
                    "variant": row.get("variant", ""),
                }
            )
    return rows


def stable_key(row: dict) -> str:
    identity = "|".join(
        (
            SEED,
            REVISION,
            row["language"],
            row["split"],
            str(row["source_row_index"]),
            row["path"],
            row["sentence_id"],
        )
    )
    return sha256_bytes(identity.encode("utf-8"))


def main() -> None:
    artifacts = verify_inputs()
    all_rows = []
    duplicate_paths = []
    row_by_path = {}
    for language in ("en", "ru"):
        for split in ("dev", "test"):
            for row in read_split(language, split):
                if row["path"] in row_by_path:
                    duplicate_paths.append(row["path"])
                row_by_path[row["path"]] = row
                all_rows.append(row)
    if duplicate_paths:
        raise RuntimeError(f"duplicate paths across audited splits: {duplicate_paths[:5]}")

    found_durations = set()
    for language in ("en", "ru"):
        duration_path = META / f"{language}-clip_durations.tsv"
        with duration_path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle, delimiter="\t", quoting=csv.QUOTE_NONE)
            if reader.fieldnames != ["clip", "duration[ms]"]:
                raise RuntimeError(f"{duration_path}: unexpected columns {reader.fieldnames}")
            for duration_row in reader:
                row = row_by_path.get(duration_row["clip"])
                if row is None:
                    continue
                if duration_row["clip"] in found_durations:
                    raise RuntimeError(f"duplicate duration for {duration_row['clip']}")
                duration_ms = int(duration_row["duration[ms]"])
                row["duration_ms"] = duration_ms
                row["duration_seconds"] = duration_ms / 1_000
                row["duration_bin"] = duration_bin(duration_ms)
                row["selection_key_sha256"] = stable_key(row)
                found_durations.add(duration_row["clip"])

    missing_durations = sorted(set(row_by_path) - found_durations)
    if missing_durations:
        raise RuntimeError(f"missing durations for {len(missing_durations)} audited rows")
    eligible = [row for row in all_rows if row["duration_bin"] is not None]

    counts = Counter(
        (row["language"], row["split"], row["duration_bin"]) for row in eligible
    )
    pool_counts = {
        language: {
            split: {
                bin_name: counts[(language, split, bin_name)]
                for bin_name in ("1-2", "2-3", "3-4")
            }
            for split in ("dev", "test")
        }
        for language in ("en", "ru")
    }
    desired_supplement = {
        bin_name: FINAL_PER_BIN - CORE_PER_BIN[bin_name]
        for bin_name in ("1-2", "2-3", "3-4")
    }
    selected = []
    shortages = []
    for language in ("en", "ru"):
        for bin_name in ("1-2", "2-3", "3-4"):
            pool = [
                row
                for row in eligible
                if row["language"] == language and row["duration_bin"] == bin_name
            ]
            target = desired_supplement[bin_name]
            if len(pool) < target:
                shortages.append(
                    {"language": language, "duration_bin": bin_name, "have": len(pool), "need": target}
                )
            selected.extend(sorted(pool, key=lambda row: row["selection_key_sha256"])[:target])
    selected.sort(
        key=lambda row: (
            row["language"],
            row["duration_bin"],
            row["split"],
            row["source_row_index"],
        )
    )

    selection_document = {
        "schema_version": 1,
        "status": "metadata_only_selection_frozen_no_audio_or_pcm_yet",
        "inference_allowed": False,
        "purpose": "fill FLEURS core gaps to 34 fixtures per language per 1-second bin",
        "selection_seed": SEED,
        "selection_method": (
            "use only genuine complete Common Voice dev/test utterances with official clip duration; "
            "no trimming, forced alignment, or transcript modification; within language/bin sort by "
            "SHA256(seed|mirror_revision|language|split|row_index|path|sentence_id)"
        ),
        "selection_uses_transcript_content": False,
        "source": {
            "upstream_release": RELEASE,
            "upstream_license": LICENSE,
            "mirror_repository": REPOSITORY,
            "mirror_revision": REVISION,
            "mirror_is_unofficial": True,
            "mirror_readme_sha256": EXPECTED_SHA["README.md"],
        },
        "fleurs_core_manifest": str(CORE_MANIFEST),
        "fleurs_core_manifest_sha256": sha256_file(CORE_MANIFEST),
        "final_target_per_language_per_bin": FINAL_PER_BIN,
        "fleurs_core_per_language_per_bin": CORE_PER_BIN,
        "supplement_target_per_language_per_bin": desired_supplement,
        "shortages": shortages,
        "selected_count": len(selected),
        "selected": selected,
    }
    atomic_json(SELECTION, selection_document)

    audit = {
        "schema_version": 1,
        "status": "metadata_audit_complete_no_audio_download_or_model_output",
        "source": selection_document["source"],
        "access": {
            "anonymous_metadata_access": True,
            "pinned_revision_resolves": True,
            "audio_archives_present_at_pinned_revision": True,
            "caveat": (
                "The accessible Hugging Face artifact is an unofficial mirror. The official "
                "mozilla-foundation/common_voice_17_0 repository at commit "
                "11dc88355e899d1bf2df74f01b904a8544a17b33 now contains only a migration README."
            ),
        },
        "metadata_artifacts": artifacts,
        "audited_splits": ["dev", "test"],
        "audited_rows": {
            "en": sum(row["language"] == "en" for row in all_rows),
            "ru": sum(row["language"] == "ru" for row in all_rows),
        },
        "eligible_complete_utterances_1_to_4_seconds": pool_counts,
        "eligible_totals": {
            language: {
                bin_name: sum(
                    counts[(language, split, bin_name)] for split in ("dev", "test")
                )
                for bin_name in ("1-2", "2-3", "3-4")
            }
            for language in ("en", "ru")
        },
        "missing_duration_count": len(missing_durations),
        "duplicate_path_count": len(duplicate_paths),
        "selection_plan": str(SELECTION),
        "selection_plan_sha256": sha256_file(SELECTION),
        "selection_shortages": shortages,
        "selection_can_fill_balanced_102_en_102_ru": not shortages,
        "audio_downloaded": False,
        "pcm_canonicalized": False,
        "asr_or_coreml_runs": 0,
    }
    atomic_json(OUTPUT, audit)
    print(json.dumps(audit, ensure_ascii=False, sort_keys=True))
    print(f"audit_sha256={sha256_file(OUTPUT)}")
    print(f"selection_plan_sha256={sha256_file(SELECTION)}")


if __name__ == "__main__":
    main()
