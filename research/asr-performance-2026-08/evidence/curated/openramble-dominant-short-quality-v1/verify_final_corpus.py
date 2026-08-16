#!/usr/bin/env python3
"""Independent fail-closed verification of the sealed 204-row CPU corpus."""

from __future__ import annotations

import csv
import hashlib
import json
import math
import os
import struct
import subprocess
from collections import Counter, defaultdict
from pathlib import Path


ROOT = Path("$TMP/openramble-dominant-short-quality-v1")
FINAL_ROOT = ROOT / "final-corpus"
MANIFEST_PATH = FINAL_ROOT / "manifest.json"
SELECTION_PATH = ROOT / "supplement-audit" / "common-voice-17" / "SELECTION_PLAN.json"
CORE_PATH = ROOT / "corpus" / "manifest.json"
PREREG_PATH = ROOT / "PREREGISTRATION.json"
EVALUATOR_PATH = ROOT / "evaluate_one_shot.py"
SEALER_PATH = ROOT / "seal_final_preregistration.py"
OUTPUT_PATH = ROOT / "FINAL_VERIFICATION.json"
META = ROOT / "supplement-audit" / "common-voice-17" / "meta"

EXPECTED = {
    SELECTION_PATH: "de0e219fc3f21ec7cd7d400bc691cb58c5d400f85551ea306c7fecac238c8456",
    CORE_PATH: "994154cd47313f2ee275716f2b6da1c43c689a211178cedaaa93086c7e3c1407",
    PREREG_PATH: "fc11882edf45b3727d124f5689a6fb179e8e7123b8437498226c00c41a5dd719",
    EVALUATOR_PATH: "e0ec47123c4e31b83da0e1ebf067f9e1f1ae10488362e967739b731491b8397d",
    SEALER_PATH: "2ea7fd7251dd027dcadc6f6287affe4adf384021e02f8bd14f0676b0654ac6aa",
    META / "en-dev.tsv": "d2fae3f98cbf44c7c47d6cc94449e2b6b68400c2048d73a19cb645b5df642236",
    META / "en-test.tsv": "b4d4db369413fcacacebee7de48e94c96c4f63383d6582e18a9b0856c5c8461a",
    META / "ru-dev.tsv": "e031512f0c4e18799ec6c0472552b697b069c5fc905317e0a5de9394458b81a1",
    META / "ru-test.tsv": "15162124bd657adea07695c22508b8bad174c282dcafe2302faaed05645cc59a",
}
REVISION = "8262c16bf297c87a9cd88c51997c4758ed7a8ba2"
PARENT_TEMPLATE_SEALER_SHA = "72c339777d6b81d3b60e4a9760b06001878305eee4eb43306d28bb095ab7656a"


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


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


def duration_bin(seconds: float) -> str | None:
    if 1.0 <= seconds < 2.0:
        return "1-2"
    if 2.0 <= seconds < 3.0:
        return "2-3"
    if 3.0 <= seconds <= 4.0:
        return "3-4"
    return None


def require_hex64(value: object, field: str) -> str:
    if not isinstance(value, str) or len(value) != 64:
        raise RuntimeError(f"{field}: not a 64-character digest")
    int(value, 16)
    return value


def verify_pcm(path: Path, fixture: dict) -> None:
    data = path.read_bytes()
    if not data or len(data) % 4:
        raise RuntimeError(f"{fixture['id']}: malformed f32le PCM")
    if len(data) != fixture["pcm_size"] or len(data) // 4 != fixture["sample_count"]:
        raise RuntimeError(f"{fixture['id']}: PCM size/sample count mismatch")
    for (sample,) in struct.iter_unpack("<f", data):
        if not math.isfinite(sample):
            raise RuntimeError(f"{fixture['id']}: non-finite PCM sample")
    seconds = fixture["sample_count"] / 16000.0
    if fixture["duration_seconds"] != seconds:
        raise RuntimeError(f"{fixture['id']}: PCM duration field mismatch")
    if duration_bin(seconds) != fixture["duration_bin"]:
        raise RuntimeError(f"{fixture['id']}: canonical PCM duration bin mismatch")


def metadata_tables() -> dict[tuple[str, str], list[dict[str, str]]]:
    tables = {}
    for language in ("en", "ru"):
        for split in ("dev", "test"):
            path = META / f"{language}-{split}.tsv"
            with path.open("r", encoding="utf-8", newline="") as handle:
                rows = list(csv.DictReader(handle, delimiter="\t", quoting=csv.QUOTE_NONE))
            for index, row in enumerate(rows):
                if row["locale"] != language:
                    raise RuntimeError(f"{path}:{index + 2}: locale mismatch")
            tables[(language, split)] = rows
    return tables


def verify_archive_accounting(manifest: dict) -> dict:
    archive_path = Path(manifest["download"]["archive_index"])
    if sha256_file(archive_path) != manifest["download"]["archive_index_sha256"]:
        raise RuntimeError("archive index SHA mismatch")
    archive = load(archive_path)
    if archive.get("revision") != REVISION or archive.get("full_archives_not_downloaded") is not True:
        raise RuntimeError("archive index revision/mode mismatch")
    if archive.get("selected_complete_source_files_retained") != 180:
        raise RuntimeError("archive index selected file count mismatch")
    if archive.get("nonselected_complete_source_files_retained") != 0:
        raise RuntimeError("archive index retained nonselected sources")
    records = archive.get("archives", [])
    segments = archive.get("segments", [])
    if len(records) != 4 or len(segments) != 64:
        raise RuntimeError("archive/segment count mismatch")
    if any(
        not record.get("directory_header_valid")
        or not record.get("all_member_headers_valid")
        or not record.get("two_block_terminator_valid")
        for record in records
    ):
        raise RuntimeError("archive structural validation is not fully green")
    if sum(record["member_count"] for record in records) != 53192:
        raise RuntimeError("validated archive member count mismatch")
    if sum(record["selected_members"] for record in records) != 180:
        raise RuntimeError("selected archive member count mismatch")
    if sum(record["selected_source_bytes"] for record in records) != manifest["download"]["selected_source_bytes"]:
        raise RuntimeError("archive selected byte accounting mismatch")
    if any(record["boundary_count"] != 16 for record in records):
        raise RuntimeError("archive boundary count mismatch")
    for record in records:
        require_hex64(record["archive_linked_etag"], "archive linked ETag")
        require_hex64(record["archive_object_etag"], "archive object ETag")
        if record["archive_linked_etag_sha256"] != sha256_bytes(record["archive_linked_etag"].encode()):
            raise RuntimeError("archive linked ETag digest mismatch")
        if record["archive_object_etag_sha256"] != sha256_bytes(record["archive_object_etag"].encode()):
            raise RuntimeError("archive object ETag digest mismatch")
        boundaries = record["boundaries"]
        if [item["offset"] for item in boundaries] != sorted(item["offset"] for item in boundaries):
            raise RuntimeError("archive boundary offsets are not ordered")
        if [item["index"] for item in boundaries] != sorted(item["index"] for item in boundaries):
            raise RuntimeError("archive boundary indices are not ordered")
    grouped: dict[str, list[dict]] = defaultdict(list)
    for segment in segments:
        require_hex64(segment["header_chain_sha256"], "segment header chain")
        grouped[segment["archive_path"]].append(segment)
    for record in records:
        group = sorted(grouped[record["archive_path"]], key=lambda item: item["start_offset"])
        if len(group) != 16 or group[0]["start_index"] != 0:
            raise RuntimeError("archive segment coverage start mismatch")
        for left, right in zip(group, group[1:]):
            if left["end_index"] != right["start_index"] or left["end_offset"] != right["start_offset"]:
                raise RuntimeError("archive segment coverage gap/overlap")
        if group[-1]["end_index"] != record["member_count"]:
            raise RuntimeError("archive segment coverage end mismatch")
        if group[-1]["end_offset"] != record["computed_terminator_offset"]:
            raise RuntimeError("archive terminator offset mismatch")
        if sum(item["member_count"] for item in group) != record["member_count"]:
            raise RuntimeError("archive segment member accounting mismatch")

    receipt_path = Path(manifest["download"]["receipt"])
    if sha256_file(receipt_path) != manifest["download"]["receipt_sha256"]:
        raise RuntimeError("download receipt SHA mismatch")
    receipt = load(receipt_path)
    manifest_download = dict(manifest["download"])
    manifest_download.pop("receipt")
    manifest_download.pop("receipt_sha256")
    if receipt != manifest_download:
        raise RuntimeError("manifest/download receipt content mismatch")
    expected_requests = (
        receipt["validated_archive_member_count"]
        + receipt["boundary_probe_bytes"] // 512
        + receipt["selected_file_count"]
        + 4  # directory headers
        + 4  # two-block terminator reads
    )
    if receipt["cdn_range_requests"] != expected_requests:
        raise RuntimeError("CDN range request accounting mismatch")
    expected_body = (
        receipt["unique_tar_member_header_bytes"]
        + receipt["boundary_probe_bytes"]
        + receipt["selected_source_bytes"]
        + 4 * 512
        + 4 * 1024
    )
    if receipt["range_payload_bytes"] != expected_body:
        raise RuntimeError("CDN body-byte accounting mismatch")
    if receipt["cdn_non_206_responses"] != 0:
        raise RuntimeError("non-206 CDN response recorded")
    return {
        "archive_count": len(records),
        "validated_archive_member_count": receipt["validated_archive_member_count"],
        "cdn_range_requests": receipt["cdn_range_requests"],
        "selected_source_bytes": receipt["selected_source_bytes"],
        "range_payload_bytes": receipt["range_payload_bytes"],
        "total_http_response_body_bytes": receipt["total_http_response_body_bytes"],
    }


def verify_indices(manifest: dict) -> None:
    fixtures = manifest["fixtures"]
    expected_source = "".join(
        f"{fixture['source_sha256']}  {fixture['source_path']}\n"
        for fixture in sorted(fixtures, key=lambda item: item["source_path"])
    )
    expected_pcm = "".join(
        f"{fixture['pcm_f32le_sha256']}  {fixture['pcm_path']}\n"
        for fixture in sorted(fixtures, key=lambda item: item["pcm_path"])
    )
    expected_reference = "".join(
        f"{fixture['reference_sha256']}  {fixture['id']}\n"
        for fixture in sorted(fixtures, key=lambda item: item["id"])
    )
    for key, expected_content in (
        ("source", expected_source),
        ("pcm", expected_pcm),
        ("reference", expected_reference),
    ):
        path = Path(manifest["indices"][key])
        if path.read_text(encoding="utf-8") != expected_content:
            raise RuntimeError(f"{key} index content mismatch")
        if sha256_file(path) != manifest["indices"][f"{key}_sha256"]:
            raise RuntimeError(f"{key} index SHA mismatch")


def main() -> None:
    if OUTPUT_PATH.exists():
        raise RuntimeError(f"refusing to overwrite verification: {OUTPUT_PATH}")
    for path, expected in EXPECTED.items():
        actual = sha256_file(path)
        if actual != expected:
            raise RuntimeError(f"frozen input mutated: {path}: {actual} != {expected}")
    parent_prereg = load(PREREG_PATH)
    if parent_prereg.get("sealing", {}).get("sealer_sha256") != PARENT_TEMPLATE_SEALER_SHA:
        raise RuntimeError("blocked parent preregistration sealer provenance mutated")
    manifest = load(MANIFEST_PATH)
    manifest_sealer_records = [
        item for item in manifest.get("frozen_inputs", [])
        if item.get("path") == str(SEALER_PATH)
    ]
    if manifest_sealer_records != [
        {"path": str(SEALER_PATH), "sha256": PARENT_TEMPLATE_SEALER_SHA}
    ]:
        raise RuntimeError("manifest does not preserve parent-template sealer provenance")
    if manifest.get("status") != "sealed_before_inference":
        raise RuntimeError("manifest status mismatch")
    if manifest.get("model_outputs_inspected") is not False:
        raise RuntimeError("manifest does not attest model_outputs_inspected=false")
    if manifest.get("scope") != "internal_evaluation_only_unofficial_mirror":
        raise RuntimeError("manifest internal-only scope mismatch")
    if manifest.get("distribution_allowed") is not False:
        raise RuntimeError("manifest must prohibit assembled-corpus distribution")
    if manifest.get("asr_or_coreml_runs") != 0:
        raise RuntimeError("manifest reports ASR/CoreML activity")

    fixtures = manifest.get("fixtures", [])
    if len(fixtures) != 204:
        raise RuntimeError("manifest must contain 204 fixtures")
    ids = [fixture["id"] for fixture in fixtures]
    if len(ids) != len(set(ids)):
        raise RuntimeError("duplicate fixture ID")
    core = load(CORE_PATH)
    core_by_id = {fixture["id"]: fixture for fixture in core["fixtures"]}
    selection = load(SELECTION_PATH)
    selected_by_key = {
        (row["language"], row["split"], row["path"]): row
        for row in selection["selected"]
    }
    if len(selected_by_key) != 180:
        raise RuntimeError("frozen selection identity count mismatch")
    tables = metadata_tables()

    seen_core = set()
    seen_selection = set()
    source_hashes = []
    pcm_hashes = []
    common_source_paths = set()
    common_pcm_paths = set()
    duration_deltas = []
    for fixture in fixtures:
        source_path = Path(fixture["source_path"])
        pcm_path = Path(fixture["pcm_path"])
        if not source_path.is_file() or not pcm_path.is_file():
            raise RuntimeError(f"{fixture['id']}: missing source/PCM")
        if sha256_file(source_path) != fixture["source_sha256"]:
            raise RuntimeError(f"{fixture['id']}: source SHA mismatch")
        if sha256_file(pcm_path) != fixture["pcm_f32le_sha256"]:
            raise RuntimeError(f"{fixture['id']}: PCM SHA mismatch")
        if sha256_bytes(fixture["reference"].encode("utf-8")) != fixture["reference_sha256"]:
            raise RuntimeError(f"{fixture['id']}: reference SHA mismatch")
        pcm_hashes.append(fixture["pcm_f32le_sha256"])
        if fixture["id"] in core_by_id:
            if fixture != core_by_id[fixture["id"]]:
                raise RuntimeError(f"{fixture['id']}: frozen FLEURS fixture mutated")
            seen_core.add(fixture["id"])
            continue

        if fixture.get("mirror_is_unofficial") is not True:
            raise RuntimeError(f"{fixture['id']}: unofficial mirror flag missing")
        if fixture.get("corpus_access") != "internal_evaluation_only":
            raise RuntimeError(f"{fixture['id']}: internal-only flag missing")
        if fixture.get("license") != "CC0-1.0 as declared by pinned unofficial mirror":
            raise RuntimeError(f"{fixture['id']}: declared license field mismatch")
        if fixture.get("source_revision") != REVISION:
            raise RuntimeError(f"{fixture['id']}: source revision mismatch")
        if not fixture.get("no_trim") or not fixture.get("no_forced_alignment") or not fixture.get("no_transcript_truncation"):
            raise RuntimeError(f"{fixture['id']}: complete-utterance flags missing")
        if fixture.get("source_transform") != "none_complete_utterance":
            raise RuntimeError(f"{fixture['id']}: forbidden source transform")
        key = (fixture["language"], fixture["source_split"], fixture["source_filename"])
        row = selected_by_key.get(key)
        if row is None or key in seen_selection:
            raise RuntimeError(f"{fixture['id']}: absent/duplicate frozen selection identity")
        seen_selection.add(key)
        metadata_row = tables[(fixture["language"], fixture["source_split"])][fixture["source_row_index"]]
        if metadata_row["locale"] != fixture["language"]:
            raise RuntimeError(f"{fixture['id']}: metadata locale mismatch")
        if metadata_row["path"] != fixture["source_filename"]:
            raise RuntimeError(f"{fixture['id']}: metadata path mismatch")
        if metadata_row["sentence"] != fixture["reference"] or fixture["reference"] != row["reference"]:
            raise RuntimeError(f"{fixture['id']}: metadata/reference mismatch")
        if fixture["reference_sha256"] != row["reference_sha256"]:
            raise RuntimeError(f"{fixture['id']}: frozen reference digest mismatch")
        if fixture["duration_bin"] != row["duration_bin"]:
            raise RuntimeError(f"{fixture['id']}: frozen duration bin mismatch")
        if fixture["declared_duration_ms"] != row["duration_ms"]:
            raise RuntimeError(f"{fixture['id']}: declared duration mismatch")
        if fixture["source_archive_range_end"] - fixture["source_archive_range_start"] + 1 != fixture["source_size"]:
            raise RuntimeError(f"{fixture['id']}: source range/size mismatch")
        require_hex64(fixture["source_archive_member_header_sha256"], "member header SHA")
        source = source_path.read_bytes()
        if len(source) != fixture["source_size"]:
            raise RuntimeError(f"{fixture['id']}: source size mismatch")
        if not (source.startswith(b"ID3") or source.startswith(b"\xff\xfb") or source.startswith(b"\xff\xf3")):
            raise RuntimeError(f"{fixture['id']}: source is not MP3")
        verify_pcm(pcm_path, fixture)
        source_hashes.append(fixture["source_sha256"])
        common_source_paths.add(source_path)
        common_pcm_paths.add(pcm_path)
        duration_deltas.append(fixture["duration_delta_seconds"])

    if seen_core != set(core_by_id) or seen_selection != set(selected_by_key):
        raise RuntimeError("not every frozen core/selection fixture is present exactly once")
    if len(source_hashes) != len(set(source_hashes)) or len(source_hashes) != 180:
        raise RuntimeError("Common Voice compressed source SHA duplication")
    if len(pcm_hashes) != len(set(pcm_hashes)) or len(pcm_hashes) != 204:
        raise RuntimeError("final PCM SHA duplication")
    disk_sources = set((FINAL_ROOT / "source" / "common-voice-17").rglob("*.mp3"))
    disk_pcm = set((FINAL_ROOT / "pcm" / "common-voice-17").rglob("*.f32le"))
    if disk_sources != common_source_paths or disk_pcm != common_pcm_paths:
        raise RuntimeError("missing/extra Common Voice source or PCM file on disk")

    counts = Counter((fixture["language"], fixture["duration_bin"]) for fixture in fixtures)
    expected_counts = {
        (language, bin_name): 34
        for language in ("en", "ru")
        for bin_name in ("1-2", "2-3", "3-4")
    }
    if dict(counts) != expected_counts:
        raise RuntimeError(f"language/bin count mismatch: {counts}")
    if manifest["counts"]["by_language_duration_bin"] != {
        language: {bin_name: 34 for bin_name in ("1-2", "2-3", "3-4")}
        for language in ("en", "ru")
    }:
        raise RuntimeError("manifest count summary mismatch")

    excluded_pcm = set()
    for path in (
        Path("$TMP/openramble-short-quality-gate/corpus/manifest.json"),
        Path("$TMP/openramble-intermediate-quality-gate/corpus/manifest.json"),
    ):
        for fixture in load(path)["fixtures"]:
            if fixture.get("pcm_f32le_sha256"):
                excluded_pcm.add(fixture["pcm_f32le_sha256"])
    if set(pcm_hashes) & excluded_pcm:
        raise RuntimeError("prior-corpus PCM overlap")
    if manifest["exclusions"]["selected_pcm_sha256_overlap_count"] != 0:
        raise RuntimeError("manifest reports PCM overlap")
    if any(value != 0 for value in manifest["fail_closed_checks"].values()):
        raise RuntimeError("manifest fail-closed counters are not all zero")

    verify_indices(manifest)
    archive_summary = verify_archive_accounting(manifest)
    jsonl_outputs = sorted(str(path) for path in ROOT.rglob("*.jsonl"))
    if jsonl_outputs:
        raise RuntimeError(f"unexpected model-output JSONL files: {jsonl_outputs}")
    git_status = subprocess.run(
        ["git", "status", "--short"],
        cwd="$REPO",
        check=True,
        text=True,
        capture_output=True,
    ).stdout
    if git_status:
        raise RuntimeError(f"shared repo is dirty: {git_status!r}")
    git_head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd="$REPO",
        check=True,
        text=True,
        capture_output=True,
    ).stdout.strip()

    verification = {
        "schema_version": 1,
        "status": "passed_before_corrected_frozen_sealer",
        "passed": True,
        "manifest": str(MANIFEST_PATH),
        "manifest_sha256": sha256_file(MANIFEST_PATH),
        "counts": manifest["counts"],
        "archive_and_download": archive_summary,
        "compressed_source_sha256": {"count": 180, "unique": 180, "all_recomputed": True},
        "canonical_pcm_sha256": {"count": 204, "unique": 204, "all_recomputed": True},
        "reference_sha256": {"count": 204, "all_recomputed": True},
        "duration_delta_seconds": {
            "minimum": min(duration_deltas),
            "maximum": max(duration_deltas),
            "maximum_absolute": max(abs(value) for value in duration_deltas),
        },
        "fail_closed": {
            "missing": 0,
            "duplicate_source": 0,
            "duplicate_pcm": 0,
            "hash_mismatch": 0,
            "locale_mismatch": 0,
            "bin_mismatch": 0,
            "prior_pcm_overlap": 0,
            "unexpected_model_output_jsonl": 0,
        },
        "model_outputs_inspected": False,
        "asr_or_coreml_runs": 0,
        "authorized_sealer_correction": {
            "reason": "replace contradictory blocked-only prose in armed output",
            "parent_template_sealer_sha256": PARENT_TEMPLATE_SEALER_SHA,
            "corrected_sealer_sha256": EXPECTED[SEALER_PATH],
            "corpus_rows_references_pcm_evaluator_gates_changed": False,
        },
        "shared_repo_head": git_head,
        "shared_repo_clean": True,
        "frozen_inputs": [
            {"path": str(path), "sha256": expected}
            for path, expected in sorted(EXPECTED.items(), key=lambda item: str(item[0]))
        ],
    }
    atomic_json(OUTPUT_PATH, verification)
    print(json.dumps(verification, ensure_ascii=False, sort_keys=True))
    print(f"verification_sha256={sha256_file(OUTPUT_PATH)}")


if __name__ == "__main__":
    main()
