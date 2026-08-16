#!/usr/bin/env python3
"""Plan and freeze a model-output-untouched dominant-short FLEURS core."""

from __future__ import annotations

import argparse
import array
import csv
import hashlib
import json
import math
import os
import struct
import sys
from collections import Counter, defaultdict
from pathlib import Path


ROOT = Path("$TMP/openramble-dominant-short-quality-v1")
META = ROOT / "corpus" / "meta"
SOURCE = ROOT / "corpus" / "source"
PCM = ROOT / "corpus" / "pcm"
PLAN = ROOT / "corpus" / "selection-plan.json"
MANIFEST = ROOT / "corpus" / "manifest.json"
PCM_INDEX = ROOT / "corpus" / "pcm-index.sha256"
SOURCE_INDEX = ROOT / "corpus" / "source-index.sha256"

DATASET = "google/fleurs"
REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
LICENSE = "CC BY 4.0"
SEED = "openramble-dominant-short-fleurs-core-v1-20260814"
ENGINEERING = Path("$TMP/openramble-short-quality-gate/corpus/manifest.json")
HOLDOUT = Path("$TMP/openramble-intermediate-quality-gate/corpus/manifest.json")
TARGET_PER_LANGUAGE = 100
MIN_SAMPLES = 16_000
MAX_SAMPLES = 64_000

EXPECTED_TSV_SHA = {
    ("en_us", "train"): "3ccfc83672cc03a835143e325abb38b4163e3a21725bc1a7d1165bc309b95852",
    ("en_us", "test"): "74c046239374deeb60fa63f258f907388093a32bcaa3140965f70ef05c79f7ca",
    ("en_us", "validation"): "9d57ee7e91e9d4c92edb39f6bbea668ef8dc2a3ff96eb510d5580b2ad05d17ec",
    ("ru_ru", "train"): "a18a051553daba44130d323ff8c7387dcde64ce855ade317c53209c0922885dc",
    ("ru_ru", "test"): "cd54f261220f49afbb4c128633a737eca4a22f6c0a8233d3cc891478d06676e6",
    ("ru_ru", "validation"): "25d9dc88a7533fc0f303354a8e6d3c8186c557229c9a0024487090a11226171e",
}

ARCHIVES = {
    ("en_us", "train"): {
        "size": 1_380_572_241,
        "linked_etag_sha256": "5f4491948c2bd29ac00f4b8afae2378f0a1dcdde4041b5cd284a80dff01fa9f5",
    },
    ("en_us", "test"): {
        "size": 289_851_356,
        "linked_etag_sha256": "d9c2e37b41aacd41bc283554a0a82b5476b36887049774ecb2819dcaaa55a356",
    },
    ("ru_ru", "train"): {
        "size": 1_427_743_798,
        "linked_etag_sha256": "1966e34c17d612317f03916fb45159c793947de77e1988fe76b3b53cf6c40b44",
    },
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


def duration_bin(samples: int) -> str | None:
    if 16_000 <= samples < 32_000:
        return "1-2"
    if 32_000 <= samples < 48_000:
        return "2-3"
    if 48_000 <= samples <= 64_000:
        return "3-4"
    return None


def read_tsv(config: str, split: str) -> tuple[list[dict], dict]:
    path = META / f"{config}-{split}.tsv"
    actual_sha = sha256_file(path)
    expected_sha = EXPECTED_TSV_SHA[(config, split)]
    if actual_sha != expected_sha:
        raise RuntimeError(f"{path}: SHA {actual_sha} != pinned {expected_sha}")
    rows = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        for tsv_index, fields in enumerate(
            csv.reader(handle, delimiter="\t", quoting=csv.QUOTE_NONE)
        ):
            if len(fields) != 7:
                raise RuntimeError(f"{path}:{tsv_index + 1}: expected 7 fields, got {len(fields)}")
            source_id, filename, raw_reference, reference, characters, sample_text, gender = fields
            sample_count = int(sample_text)
            rows.append(
                {
                    "source_id": int(source_id),
                    "filename": filename,
                    "raw_reference": raw_reference,
                    "reference": reference,
                    "characters": characters,
                    "sample_count": sample_count,
                    "gender": gender.casefold(),
                    "source_tsv_row_index": tsv_index,
                }
            )
    if len({row["filename"] for row in rows}) != len(rows):
        raise RuntimeError(f"{path}: duplicate filename")
    for dataset_index, row in enumerate(sorted(rows, key=lambda item: item["filename"])):
        row["source_row_index"] = dataset_index
    return rows, {
        "path": str(path),
        "sha256": actual_sha,
        "row_count": len(rows),
        "source_url": (
            f"https://huggingface.co/datasets/{DATASET}/resolve/{REVISION}/"
            f"data/{config}/{'dev' if split == 'validation' else split}.tsv"
        ),
    }


def stable_key(config: str, split: str, row: dict) -> str:
    identity = "|".join(
        (
            SEED,
            REVISION,
            config,
            split,
            str(row["source_row_index"]),
            str(row["source_id"]),
            row["filename"],
        )
    )
    return sha256_bytes(identity.encode("utf-8"))


def load_exclusions() -> tuple[list[dict], set[tuple], set[str]]:
    manifests = []
    identities: set[tuple] = set()
    pcm_hashes: set[str] = set()
    for role, path in (("engineering", ENGINEERING), ("holdout", HOLDOUT)):
        document = json.loads(path.read_text(encoding="utf-8"))
        manifests.append(
            {
                "role": role,
                "path": str(path),
                "sha256": sha256_file(path),
                "fixture_count": len(document["fixtures"]),
            }
        )
        for fixture in document["fixtures"]:
            if fixture.get("source") == DATASET:
                identities.add(
                    (
                        fixture.get("source_revision"),
                        fixture.get("source_config"),
                        fixture.get("source_split"),
                        int(fixture.get("source_row_index")),
                    )
                )
            pcm_sha = fixture.get("pcm_f32le_sha256")
            if pcm_sha:
                pcm_hashes.add(pcm_sha)
    return manifests, identities, pcm_hashes


def make_plan() -> dict:
    exclusion_manifests, excluded_identities, excluded_pcm_hashes = load_exclusions()
    metadata = []
    pools: dict[str, list[dict]] = defaultdict(list)
    audit_counts: Counter = Counter()
    validation_short_rows = []
    identity_overlap = []
    for config in ("en_us", "ru_ru"):
        for split in ("train", "test", "validation"):
            rows, metadata_item = read_tsv(config, split)
            metadata.append(metadata_item)
            for row in rows:
                bin_name = duration_bin(row["sample_count"])
                if bin_name is None:
                    continue
                identity = (REVISION, config, split, row["source_row_index"])
                language = "en" if config == "en_us" else "ru"
                audit_counts[(language, split, bin_name, "all")] += 1
                if identity in excluded_identities:
                    audit_counts[(language, split, bin_name, "excluded")] += 1
                    identity_overlap.append(identity)
                    continue
                if split == "validation":
                    validation_short_rows.append((config, row["source_row_index"]))
                    continue
                candidate = dict(row)
                candidate.update(
                    {
                        "source_config": config,
                        "source_split": split,
                        "language": language,
                        "duration_bin": bin_name,
                        "duration_seconds": row["sample_count"] / 16_000,
                        "selection_key_sha256": stable_key(config, split, row),
                    }
                )
                pools[language].append(candidate)
                audit_counts[(language, split, bin_name, "eligible")] += 1

    balanced_count = min(len(pools["en"]), len(pools["ru"]), TARGET_PER_LANGUAGE)
    selected = []
    for language in ("en", "ru"):
        selected.extend(
            sorted(pools[language], key=lambda row: row["selection_key_sha256"])[
                :balanced_count
            ]
        )
    selected.sort(
        key=lambda row: (
            row["language"],
            row["source_split"],
            row["source_row_index"],
        )
    )

    wanted_dir = ROOT / "corpus" / "wanted-members"
    wanted_dir.mkdir(parents=True, exist_ok=True)
    grouped: dict[tuple[str, str], list[str]] = defaultdict(list)
    for row in selected:
        grouped[(row["source_config"], row["source_split"])].append(
            f"{row['source_split']}/{row['filename']}"
        )
    wanted_files = []
    for key, members in sorted(grouped.items()):
        path = wanted_dir / f"{key[0]}-{key[1]}.txt"
        path.write_text("".join(f"{member}\n" for member in sorted(members)), encoding="utf-8")
        archive = ARCHIVES[key]
        wanted_files.append(
            {
                "source_config": key[0],
                "source_split": key[1],
                "path": str(path),
                "sha256": sha256_file(path),
                "member_count": len(members),
                "archive_size": archive["size"],
                "archive_linked_etag_sha256": archive["linked_etag_sha256"],
                "archive_url": (
                    f"https://huggingface.co/datasets/{DATASET}/resolve/{REVISION}/"
                    f"data/{key[0]}/audio/{key[1]}.tar.gz"
                ),
            }
        )

    def nested_counts(status: str) -> dict:
        result = {}
        for language in ("en", "ru"):
            result[language] = {}
            for split in ("train", "test", "validation"):
                result[language][split] = {
                    bin_name: audit_counts[(language, split, bin_name, status)]
                    for bin_name in ("1-2", "2-3", "3-4")
                }
        return result

    selection_rows = []
    for row in selected:
        selection_rows.append(
            {
                key: row[key]
                for key in (
                    "language",
                    "source_config",
                    "source_split",
                    "source_row_index",
                    "source_tsv_row_index",
                    "source_id",
                    "filename",
                    "sample_count",
                    "duration_seconds",
                    "duration_bin",
                    "gender",
                    "selection_key_sha256",
                )
            }
            | {
                "reference_sha256": sha256_bytes(row["reference"].encode("utf-8")),
                "raw_reference_sha256": sha256_bytes(
                    row["raw_reference"].encode("utf-8")
                ),
            }
        )

    plan = {
        "schema_version": 1,
        "status": "selection_frozen_before_audio_and_before_any_model_output",
        "purpose": "untouched dominant-short 1.0-4.0s EN/RU quality corpus audit",
        "dataset": DATASET,
        "dataset_revision": REVISION,
        "dataset_license": LICENSE,
        "selection_seed": SEED,
        "selection_method": (
            "audit all pinned train/test TSV rows without transcript-content selection; "
            "exclude every engineering/holdout source identity; retain 1.0<=duration<=4.0s; "
            "sort each language by SHA256(seed|revision|config|split|dataset_row|source_id|filename); "
            "take the largest equal EN/RU count up to 100"
        ),
        "selection_uses_transcript_content": False,
        "duration_bins": {
            "1-2": "16000 <= samples < 32000",
            "2-3": "32000 <= samples < 48000",
            "3-4": "48000 <= samples <= 64000",
        },
        "target": {
            "per_language": TARGET_PER_LANGUAGE,
            "balanced_duration_bins": True,
        },
        "availability": {
            "all_short_rows": nested_counts("all"),
            "excluded_short_rows": nested_counts("excluded"),
            "eligible_untouched_train_test_rows": nested_counts("eligible"),
            "eligible_en": len(pools["en"]),
            "eligible_ru": len(pools["ru"]),
            "maximum_language_balanced_count_per_language": balanced_count,
            "target_reached": balanced_count >= TARGET_PER_LANGUAGE,
            "duration_bin_balance_possible": all(
                any(row["duration_bin"] == bin_name for row in pools[language])
                for language in ("en", "ru")
                for bin_name in ("1-2", "2-3", "3-4")
            ),
            "unused_validation_short_rows": validation_short_rows,
        },
        "exclusions": {
            "manifests": exclusion_manifests,
            "unique_source_identities": len(excluded_identities),
            "unique_pcm_sha256": len(excluded_pcm_hashes),
            "selected_source_identity_overlap_count": 0,
            "short_validation_source_identities_excluded": len(identity_overlap),
            "pcm_overlap_deferred_until_canonicalization": True,
        },
        "metadata": sorted(metadata, key=lambda item: item["path"]),
        "wanted_members": wanted_files,
        "selected": selection_rows,
    }
    atomic_json(PLAN, plan)
    return plan


def read_riff_wave(source: Path) -> tuple[int, int, int, int, bytes]:
    data = source.read_bytes()
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise RuntimeError(f"{source}: not RIFF/WAVE")
    fmt = None
    payload = None
    offset = 12
    while offset + 8 <= len(data):
        chunk_id = data[offset : offset + 4]
        chunk_size = struct.unpack_from("<I", data, offset + 4)[0]
        start = offset + 8
        end = start + chunk_size
        if end > len(data):
            raise RuntimeError(f"{source}: truncated {chunk_id!r} chunk")
        if chunk_id == b"fmt ":
            if chunk_size < 16:
                raise RuntimeError(f"{source}: short fmt chunk")
            fmt = struct.unpack_from("<HHIIHH", data, start)
        elif chunk_id == b"data":
            payload = data[start:end]
        offset = end + (chunk_size & 1)
    if fmt is None or payload is None:
        raise RuntimeError(f"{source}: missing fmt/data")
    format_tag, channels, sample_rate, _, block_align, bits = fmt
    if block_align != channels * (bits // 8) or len(payload) % block_align:
        raise RuntimeError(f"{source}: invalid block alignment")
    return format_tag, channels, sample_rate, bits, payload


def canonicalize(source: Path, destination: Path, expected_samples: int) -> dict:
    format_tag, channels, sample_rate, bits, payload = read_riff_wave(source)
    if channels != 1 or sample_rate != 16_000 or (format_tag, bits) not in ((1, 16), (3, 32)):
        raise RuntimeError(
            f"{source}: expected mono 16k PCM16/Float32, got "
            f"format={format_tag} channels={channels} rate={sample_rate} bits={bits}"
        )
    frame_count = len(payload) // (bits // 8)
    if frame_count != expected_samples:
        raise RuntimeError(f"{source}: {frame_count} frames != metadata {expected_samples}")
    if format_tag == 3:
        values = struct.unpack(f"<{frame_count}f", payload)
        if not all(math.isfinite(value) for value in values):
            raise RuntimeError(f"{source}: non-finite sample")
        pcm = payload
        encoding = "IEEE-754 Float32 little-endian"
    else:
        samples = array.array("h")
        samples.frombytes(payload)
        if sys.byteorder != "little":
            samples.byteswap()
        pcm_buffer = bytearray(4 * len(samples))
        for index, sample in enumerate(samples):
            struct.pack_into("<f", pcm_buffer, index * 4, sample / 32768.0)
        pcm = bytes(pcm_buffer)
        encoding = "signed PCM16 little-endian"
    temporary = destination.with_suffix(destination.suffix + ".part")
    temporary.write_bytes(pcm)
    os.replace(temporary, destination)
    return {
        "source_sha256": sha256_file(source),
        "source_audio_encoding": encoding,
        "pcm_f32le_sha256": sha256_file(destination),
        "pcm_path": str(destination),
        "sample_rate": 16_000,
        "sample_count": frame_count,
        "duration_seconds": frame_count / 16_000,
    }


def finalize() -> dict:
    plan = json.loads(PLAN.read_text(encoding="utf-8"))
    _, excluded_identities, excluded_pcm_hashes = load_exclusions()
    row_lookup = {}
    metadata_sha = {}
    for config in ("en_us", "ru_ru"):
        for split in ("train", "test", "validation"):
            rows, metadata_item = read_tsv(config, split)
            metadata_sha[(config, split)] = metadata_item["sha256"]
            for row in rows:
                row_lookup[(config, split, row["source_row_index"])] = row

    PCM.mkdir(parents=True, exist_ok=True)
    fixtures = []
    source_identity_overlap = []
    for selected in plan["selected"]:
        config = selected["source_config"]
        split = selected["source_split"]
        row_index = selected["source_row_index"]
        row = row_lookup[(config, split, row_index)]
        identity = (REVISION, config, split, row_index)
        if identity in excluded_identities:
            source_identity_overlap.append(identity)
        source_path = SOURCE / config / split / row["filename"]
        if not source_path.is_file():
            raise RuntimeError(f"missing selected source: {source_path}")
        stem = f"fleurs-dominant-short-{config}-{split}-{row_index:04d}-{row['source_id']}-{Path(row['filename']).stem}"
        pcm_path = PCM / f"{stem}.f32le"
        audio = canonicalize(source_path, pcm_path, row["sample_count"])
        fixtures.append(
            {
                "id": stem,
                "suite": "fleurs_dominant_short_core",
                "kind": "real_public_reference",
                "scored": True,
                "language": selected["language"],
                "language_hint": selected["language"],
                "duration_bin": selected["duration_bin"],
                "reference": row["reference"],
                "raw_reference": row["raw_reference"],
                "reference_sha256": sha256_bytes(row["reference"].encode("utf-8")),
                "raw_reference_sha256": sha256_bytes(row["raw_reference"].encode("utf-8")),
                "source": DATASET,
                "source_revision": REVISION,
                "source_config": config,
                "source_split": split,
                "source_row_index": row_index,
                "source_tsv_row_index": row["source_tsv_row_index"],
                "source_id": row["source_id"],
                "source_filename": row["filename"],
                "source_tsv_sha256": metadata_sha[(config, split)],
                "source_archive_url": (
                    f"https://huggingface.co/datasets/{DATASET}/resolve/{REVISION}/"
                    f"data/{config}/audio/{split}.tar.gz"
                ),
                "source_archive_linked_etag_sha256": ARCHIVES[(config, split)][
                    "linked_etag_sha256"
                ],
                "source_archive_member": f"{split}/{row['filename']}",
                "source_path": str(source_path),
                "source_url": f"https://huggingface.co/datasets/{DATASET}",
                "license": LICENSE,
                "gender": row["gender"],
                "selection_key_sha256": selected["selection_key_sha256"],
                **audio,
            }
        )
    fixtures.sort(key=lambda fixture: fixture["id"])
    pcm_hashes = [fixture["pcm_f32le_sha256"] for fixture in fixtures]
    pcm_overlap = sorted(set(pcm_hashes) & excluded_pcm_hashes)
    if source_identity_overlap:
        raise RuntimeError(f"source identity overlap: {source_identity_overlap}")
    if pcm_overlap:
        raise RuntimeError(f"excluded PCM overlap: {pcm_overlap}")
    if len(set(pcm_hashes)) != len(pcm_hashes):
        raise RuntimeError("duplicate PCM SHA within selected corpus")

    counts_by_language_bin = {
        language: {
            bin_name: sum(
                fixture["language"] == language and fixture["duration_bin"] == bin_name
                for fixture in fixtures
            )
            for bin_name in ("1-2", "2-3", "3-4")
        }
        for language in ("en", "ru")
    }
    target_reached = all(
        sum(counts_by_language_bin[language].values()) >= TARGET_PER_LANGUAGE
        for language in ("en", "ru")
    )
    bin_balance_reached = all(
        counts_by_language_bin[language][bin_name] > 0
        for language in ("en", "ru")
        for bin_name in ("1-2", "2-3", "3-4")
    )
    manifest = {
        "schema_version": 1,
        "status": "sealed_before_inference_underpowered_requires_pinned_supplement",
        "inference_allowed": False,
        "inference_blockers": [
            "target >=100 EN and >=100 RU is not met",
            "duration bins 1-2s and 2-3s are empty in pinned untouched FLEURS train/test",
        ],
        "selection_plan": str(PLAN),
        "selection_plan_sha256": sha256_file(PLAN),
        "selection_seed": SEED,
        "sources": {
            "dataset": DATASET,
            "dataset_revision": REVISION,
            "dataset_license": LICENSE,
            "metadata": plan["metadata"],
        },
        "canonicalization": {
            "input_requirement": "mono 16 kHz PCM16 or IEEE-754 Float32 WAV; no resampling",
            "output": "headerless little-endian IEEE-754 Float32 mono PCM",
            "mapping": "PCM16 -> float32(sample_int16 / 32768.0); Float32 -> bit-exact data-chunk copy after finite check",
            "sample_rate": 16_000,
        },
        "exclusions": {
            **plan["exclusions"],
            "pcm_overlap_deferred_until_canonicalization": False,
            "selected_source_identity_overlap_count": len(source_identity_overlap),
            "selected_pcm_sha256_overlap_count": len(pcm_overlap),
        },
        "availability": plan["availability"],
        "counts": {
            "fixtures": len(fixtures),
            "scored": len(fixtures),
            "en": sum(fixture["language"] == "en" for fixture in fixtures),
            "ru": sum(fixture["language"] == "ru" for fixture in fixtures),
            "by_language_duration_bin": counts_by_language_bin,
            "unique_pcm_sha256": len(set(pcm_hashes)),
            "target_reached": target_reached,
            "duration_bin_balance_reached": bin_balance_reached,
        },
        "supplement_required": True,
        "fixtures": fixtures,
    }
    atomic_json(MANIFEST, manifest)
    PCM_INDEX.write_text(
        "".join(
            f"{fixture['pcm_f32le_sha256']}  {fixture['pcm_path']}\n"
            for fixture in fixtures
        ),
        encoding="utf-8",
    )
    SOURCE_INDEX.write_text(
        "".join(
            f"{fixture['source_sha256']}  {fixture['source_path']}\n"
            for fixture in fixtures
        ),
        encoding="utf-8",
    )
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=("plan", "finalize"))
    args = parser.parse_args()
    if args.phase == "plan":
        document = make_plan()
        print(json.dumps(document["availability"], ensure_ascii=False, sort_keys=True))
        print(f"selection_plan={PLAN}")
        print(f"selection_plan_sha256={sha256_file(PLAN)}")
    else:
        document = finalize()
        print(json.dumps(document["counts"], ensure_ascii=False, sort_keys=True))
        print(f"manifest={MANIFEST}")
        print(f"manifest_sha256={sha256_file(MANIFEST)}")
        print(f"pcm_index_sha256={sha256_file(PCM_INDEX)}")
        print(f"source_index_sha256={sha256_file(SOURCE_INDEX)}")


if __name__ == "__main__":
    main()
