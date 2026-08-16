#!/usr/bin/env python3
"""Fetch the frozen Common Voice selection by pinned TAR byte range and seal PCM.

This script intentionally knows nothing about ASR or model outputs.  It accepts
only the already-frozen selection plan, validates each selected TAR member, and
canonicalizes each complete MP3 without trimming or alignment.
"""

from __future__ import annotations

import csv
import hashlib
import http.client
import json
import math
import os
import struct
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path("$TMP/openramble-dominant-short-quality-v1")
AUDIT_ROOT = ROOT / "supplement-audit" / "common-voice-17"
META = AUDIT_ROOT / "meta"
SELECTION_PATH = AUDIT_ROOT / "SELECTION_PLAN.json"
CORE_MANIFEST_PATH = ROOT / "corpus" / "manifest.json"
BLOCKED_PREREG_PATH = ROOT / "PREREGISTRATION.json"
EVALUATOR_PATH = ROOT / "evaluate_one_shot.py"
SEALER_PATH = ROOT / "seal_final_preregistration.py"

OUTPUT_ROOT = ROOT / "final-corpus"
SOURCE_ROOT = OUTPUT_ROOT / "source" / "common-voice-17"
PCM_ROOT = OUTPUT_ROOT / "pcm" / "common-voice-17"
RANGE_RECEIPTS = OUTPUT_ROOT / "range-receipts"
MANIFEST_PATH = OUTPUT_ROOT / "manifest.json"
SOURCE_INDEX_PATH = OUTPUT_ROOT / "source-index.sha256"
PCM_INDEX_PATH = OUTPUT_ROOT / "pcm-index.sha256"
REFERENCE_INDEX_PATH = OUTPUT_ROOT / "reference-index.sha256"
ARCHIVE_INDEX_PATH = OUTPUT_ROOT / "archive-index.json"
CANONICALIZER_PATH = OUTPUT_ROOT / "canonicalizer.json"
DOWNLOAD_RECEIPT_PATH = OUTPUT_ROOT / "download-receipt.json"

REPOSITORY = "fsicoli/common_voice_17_0"
REVISION = "8262c16bf297c87a9cd88c51997c4758ed7a8ba2"
BASE_URL = f"https://huggingface.co/datasets/{REPOSITORY}/resolve/{REVISION}"
AFCONVERT = Path("/usr/bin/afconvert")
AFINFO = Path("/usr/bin/afinfo")

EXPECTED_FROZEN_SHA = {
    SELECTION_PATH: "de0e219fc3f21ec7cd7d400bc691cb58c5d400f85551ea306c7fecac238c8456",
    CORE_MANIFEST_PATH: "994154cd47313f2ee275716f2b6da1c43c689a211178cedaaa93086c7e3c1407",
    BLOCKED_PREREG_PATH: "fc11882edf45b3727d124f5689a6fb179e8e7123b8437498226c00c41a5dd719",
    EVALUATOR_PATH: "e0ec47123c4e31b83da0e1ebf067f9e1f1ae10488362e967739b731491b8397d",
    SEALER_PATH: "72c339777d6b81d3b60e4a9760b06001878305eee4eb43306d28bb095ab7656a",
    AUDIT_ROOT / "README.md": "5d7f13a790c3f4de73ec28608570d7a4619bce675f37bdd42af47dfa6bfb0281",
    META / "en-clip_durations.tsv": "693987b4fe15a6c90733639466509474f80da95d4413f123be9cf45ff41200a6",
    META / "en-dev.tsv": "d2fae3f98cbf44c7c47d6cc94449e2b6b68400c2048d73a19cb645b5df642236",
    META / "en-test.tsv": "b4d4db369413fcacacebee7de48e94c96c4f63383d6582e18a9b0856c5c8461a",
    META / "ru-clip_durations.tsv": "5892cb96e5a9ad4318f91b363fab7b84435577449d6bed8cfbb1a9f7d31bf735",
    META / "ru-dev.tsv": "e031512f0c4e18799ec6c0472552b697b069c5fc905317e0a5de9394458b81a1",
    META / "ru-test.tsv": "15162124bd657adea07695c22508b8bad174c282dcafe2302faaed05645cc59a",
}

EXPECTED_AFCONVERT_SHA = "621019b976afbc91c5659ab479d02b1e644677951b7780023b17c5629edff194"
EXPECTED_AFINFO_SHA = "ea916cdbef8b0518ce5c8187331c4aac22fe7b24139792714e7c34e8ac324602"

ARCHIVE_SEGMENTS = 16
INDEX_WORKERS = 64
CONVERT_WORKERS = 4
PRINT_LOCK = threading.Lock()
NETWORK_LOCK = threading.Lock()
NETWORK_STATS = Counter()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_bytes(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".part")
    temporary.write_bytes(value)
    os.replace(temporary, path)


def atomic_json(path: Path, value: object) -> None:
    atomic_bytes(
        path,
        (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8"),
    )


def atomic_text(path: Path, value: str) -> None:
    atomic_bytes(path, value.encode("utf-8"))


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def validate_frozen_inputs() -> None:
    for path, expected in EXPECTED_FROZEN_SHA.items():
        if not path.is_file():
            raise RuntimeError(f"missing frozen input: {path}")
        actual = sha256_file(path)
        if actual != expected:
            raise RuntimeError(f"frozen input mutated: {path}: {actual} != {expected}")
    if sha256_file(AFCONVERT) != EXPECTED_AFCONVERT_SHA:
        raise RuntimeError("afconvert binary SHA mismatch")
    if sha256_file(AFINFO) != EXPECTED_AFINFO_SHA:
        raise RuntimeError("afinfo binary SHA mismatch")


def duration_bin(seconds: float) -> str | None:
    # Match the frozen half-open metadata bins, including exactly 4.0 seconds.
    if 1.0 <= seconds < 2.0:
        return "1-2"
    if 2.0 <= seconds < 3.0:
        return "2-3"
    if 3.0 <= seconds <= 4.0:
        return "3-4"
    return None


def parse_tsv_rows(language: str, split: str) -> list[dict[str, str]]:
    path = META / f"{language}-{split}.tsv"
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t", quoting=csv.QUOTE_NONE)
        required = {"client_id", "path", "sentence_id", "sentence", "locale"}
        if not required.issubset(reader.fieldnames or []):
            raise RuntimeError(f"{path}: missing required columns")
        rows = list(reader)
    seen = set()
    for index, row in enumerate(rows):
        if row["locale"] != language:
            raise RuntimeError(f"{path}:{index + 2}: locale mismatch")
        if row["path"] in seen:
            raise RuntimeError(f"{path}:{index + 2}: duplicate path")
        if not row["path"].endswith(".mp3") or not row["sentence"].strip():
            raise RuntimeError(f"{path}:{index + 2}: invalid path/reference")
        seen.add(row["path"])
    return rows


def selected_and_split_tables() -> tuple[list[dict], dict[tuple[str, str], list[dict]], dict[str, int]]:
    selection = load_json(SELECTION_PATH)
    if selection.get("status") != "metadata_only_selection_frozen_no_audio_or_pcm_yet":
        raise RuntimeError("unexpected frozen selection status")
    if selection.get("inference_allowed") is not False:
        raise RuntimeError("frozen selection must remain inference-blocked")
    if selection.get("source", {}).get("mirror_revision") != REVISION:
        raise RuntimeError("selection mirror revision mismatch")
    selected = selection.get("selected", [])
    if len(selected) != 180:
        raise RuntimeError(f"selection must contain 180 rows, got {len(selected)}")
    selected_keys = [(r["language"], r["split"], r["path"]) for r in selected]
    if len(set(selected_keys)) != 180:
        raise RuntimeError("duplicate identity in frozen selection")

    tables: dict[tuple[str, str], list[dict]] = {}
    wanted_paths: dict[str, set[str]] = {"en": set(), "ru": set()}
    for language in ("en", "ru"):
        for split in ("dev", "test"):
            rows = parse_tsv_rows(language, split)
            tables[(language, split)] = rows
            wanted_paths[language].update(row["path"] for row in rows)

    durations: dict[str, int] = {}
    for language in ("en", "ru"):
        path = META / f"{language}-clip_durations.tsv"
        with path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle, delimiter="\t", quoting=csv.QUOTE_NONE)
            if reader.fieldnames != ["clip", "duration[ms]"]:
                raise RuntimeError(f"{path}: unexpected columns")
            for row in reader:
                clip = row["clip"]
                if clip in wanted_paths[language]:
                    if clip in durations:
                        raise RuntimeError(f"duplicate clip duration: {clip}")
                    durations[clip] = int(row["duration[ms]"])

    all_split_paths = {
        row["path"] for rows in tables.values() for row in rows
    }
    missing_durations = all_split_paths - durations.keys()
    if missing_durations:
        raise RuntimeError(f"missing durations for split rows: {len(missing_durations)}")

    selection_counts = Counter((r["language"], r["duration_bin"]) for r in selected)
    expected_counts = {
        (language, bin_name): count
        for language in ("en", "ru")
        for bin_name, count in (("1-2", 34), ("2-3", 34), ("3-4", 22))
    }
    if dict(selection_counts) != expected_counts:
        raise RuntimeError(f"frozen selection balance mismatch: {selection_counts}")

    for selected_row in selected:
        language = selected_row["language"]
        split = selected_row["split"]
        row_index = int(selected_row["source_row_index"])
        rows = tables.get((language, split))
        if rows is None or not 0 <= row_index < len(rows):
            raise RuntimeError(f"bad selected row coordinate: {selected_row}")
        metadata_row = rows[row_index]
        if metadata_row["locale"] != language:
            raise RuntimeError(f"{selected_row['path']}: locale mismatch")
        if metadata_row["path"] != selected_row["path"]:
            raise RuntimeError(f"{selected_row['path']}: TSV row/path mismatch")
        if metadata_row["sentence_id"] != selected_row["sentence_id"]:
            raise RuntimeError(f"{selected_row['path']}: sentence_id mismatch")
        if metadata_row["sentence"] != selected_row["reference"]:
            raise RuntimeError(f"{selected_row['path']}: reference mismatch")
        reference_sha = sha256_bytes(metadata_row["sentence"].encode("utf-8"))
        if reference_sha != selected_row["reference_sha256"]:
            raise RuntimeError(f"{selected_row['path']}: reference SHA mismatch")
        duration_ms = durations[selected_row["path"]]
        if duration_ms != selected_row["duration_ms"]:
            raise RuntimeError(f"{selected_row['path']}: duration mismatch")
        if duration_bin(duration_ms / 1000.0) != selected_row["duration_bin"]:
            raise RuntimeError(f"{selected_row['path']}: declared duration bin mismatch")

    return selected, tables, durations


def octal_field(value: bytes, field_name: str) -> int:
    stripped = value.split(b"\0", 1)[0].strip()
    if not stripped:
        return 0
    try:
        return int(stripped, 8)
    except ValueError as error:
        raise RuntimeError(f"invalid TAR {field_name} field: {value!r}") from error


def validate_tar_header(
    header: bytes,
    expected_member: str,
    expected_size: int,
    allowed_types: tuple[bytes, ...] = (b"0", b"\0"),
) -> dict:
    if len(header) != 512:
        raise RuntimeError("TAR header is not 512 bytes")
    stored_checksum = octal_field(header[148:156], "checksum")
    checksum_bytes = bytearray(header)
    checksum_bytes[148:156] = b" " * 8
    computed_checksum = sum(checksum_bytes)
    if stored_checksum != computed_checksum:
        raise RuntimeError(f"{expected_member}: TAR checksum mismatch")
    name = header[:100].split(b"\0", 1)[0].decode("utf-8")
    prefix = header[345:500].split(b"\0", 1)[0].decode("utf-8")
    member = f"{prefix}/{name}" if prefix else name
    size = octal_field(header[124:136], "size")
    if member != expected_member:
        raise RuntimeError(f"TAR member mismatch at predicted offset: {member} != {expected_member}")
    if size != expected_size:
        raise RuntimeError(f"{member}: TAR size {size} != derived size {expected_size}")
    if header[156:157] not in allowed_types:
        raise RuntimeError(f"{member}: unexpected TAR type {header[156:157]!r}")
    if header[257:262] != b"ustar":
        raise RuntimeError(f"{member}: missing ustar magic")
    return {
        "member": member,
        "size": size,
        "stored_checksum": stored_checksum,
        "computed_checksum": computed_checksum,
        "header_sha256": sha256_bytes(header),
    }


class RangeReader:
    """Persistent byte-range reader for one immutable signed CDN object."""

    def __init__(self, signed_url: str):
        parsed = urlparse(signed_url)
        if parsed.scheme != "https" or not parsed.hostname:
            raise RuntimeError("archive redirect is not a valid HTTPS URL")
        self.host = parsed.hostname
        self.port = parsed.port
        self.path = parsed.path + (f"?{parsed.query}" if parsed.query else "")
        self.connection: http.client.HTTPSConnection | None = None

    def close(self) -> None:
        if self.connection is not None:
            self.connection.close()
            self.connection = None

    def get(self, start: int, end: int) -> tuple[bytes, dict[str, str]]:
        if start < 0 or end < start:
            raise RuntimeError(f"invalid range {start}-{end}")
        expected_size = end - start + 1
        last_error: Exception | None = None
        for attempt in range(6):
            try:
                if self.connection is None:
                    self.connection = http.client.HTTPSConnection(
                        self.host, port=self.port, timeout=30
                    )
                self.connection.request(
                    "GET",
                    self.path,
                    headers={
                        "Range": f"bytes={start}-{end}",
                        "Accept-Encoding": "identity",
                        "Connection": "keep-alive",
                        "User-Agent": "openramble-internal-corpus-sealer/1",
                    },
                )
                response = self.connection.getresponse()
                body = response.read()
                headers = {key.lower(): value for key, value in response.getheaders()}
                with NETWORK_LOCK:
                    NETWORK_STATS["cdn_requests"] += 1
                    NETWORK_STATS["cdn_response_body_bytes"] += len(body)
                    if response.status != 206:
                        NETWORK_STATS["cdn_non_206_responses"] += 1
                expected_content_range = f"bytes {start}-{end}/"
                if response.status != 206:
                    raise RuntimeError(f"HTTP {response.status} for range {start}-{end}")
                if len(body) != expected_size:
                    raise RuntimeError(
                        f"range {start}-{end}: body {len(body)} != {expected_size}"
                    )
                if not headers.get("content-range", "").startswith(expected_content_range):
                    raise RuntimeError(
                        f"range {start}-{end}: bad content-range {headers.get('content-range')!r}"
                    )
                return body, headers
            except (OSError, http.client.HTTPException, RuntimeError) as error:
                last_error = error
                self.close()
                if attempt == 5:
                    break
                time.sleep(min(0.25 * (2**attempt), 4.0))
        raise RuntimeError(f"range {start}-{end} failed after retries: {last_error}")


def archive_identity(language: str, split: str) -> dict:
    archive_path = f"audio/{language}/{split}/{language}_{split}_0.tar"
    archive_url = f"{BASE_URL}/{archive_path}"
    parsed = urlparse(archive_url)
    connection = http.client.HTTPSConnection(parsed.hostname, timeout=30)
    request_path = parsed.path + (f"?{parsed.query}" if parsed.query else "")
    connection.request(
        "GET",
        request_path,
        headers={
            "Range": "bytes=0-511",
            "Accept-Encoding": "identity",
            "User-Agent": "openramble-internal-corpus-sealer/1",
        },
    )
    response = connection.getresponse()
    redirect_body = response.read()
    headers = {key.lower(): value for key, value in response.getheaders()}
    connection.close()
    with NETWORK_LOCK:
        NETWORK_STATS["redirect_requests"] += 1
        NETWORK_STATS["redirect_response_body_bytes"] += len(redirect_body)
    if response.status not in (302, 303, 307, 308):
        raise RuntimeError(f"{archive_path}: expected pinned redirect, got HTTP {response.status}")
    signed_url = headers.get("location")
    linked_etag = headers.get("x-linked-etag", "").strip('"')
    if not signed_url or not linked_etag:
        raise RuntimeError(f"{archive_path}: redirect lacks location/x-linked-etag")
    reader = RangeReader(signed_url)
    try:
        directory_header, final_headers = reader.get(0, 511)
    finally:
        reader.close()
    expected_directory = f"{language}_{split}_0/"
    directory = validate_tar_header(
        directory_header, expected_directory, 0, allowed_types=(b"5",)
    )
    content_range = final_headers["content-range"]
    archive_size = int(content_range.split("/", 1)[1])
    object_etag = final_headers.get("etag", "").strip('"')
    if not object_etag or final_headers.get("accept-ranges", "bytes") != "bytes":
        raise RuntimeError(f"{archive_path}: immutable byte-range provenance unavailable")
    return {
        "language": language,
        "split": split,
        "archive_path": archive_path,
        "archive_url": archive_url,
        "archive_size": archive_size,
        "archive_linked_etag": linked_etag,
        "archive_linked_etag_sha256": sha256_bytes(linked_etag.encode("utf-8")),
        "archive_object_etag": object_etag,
        "archive_object_etag_sha256": sha256_bytes(object_etag.encode("utf-8")),
        "archive_directory_header_sha256": directory["header_sha256"],
        "_signed_url": signed_url,
    }


def maybe_tar_header(header: bytes, expected_prefix: str, known_names: set[str]) -> dict | None:
    if len(header) != 512 or header[257:262] != b"ustar":
        return None
    try:
        stored_checksum = octal_field(header[148:156], "checksum")
    except RuntimeError:
        return None
    checksum_bytes = bytearray(header)
    checksum_bytes[148:156] = b" " * 8
    if stored_checksum != sum(checksum_bytes):
        return None
    name = header[:100].split(b"\0", 1)[0].decode("utf-8", "strict")
    if not name.startswith(expected_prefix):
        return None
    filename = name[len(expected_prefix) :]
    if filename not in known_names:
        return None
    try:
        size = octal_field(header[124:136], "size")
    except RuntimeError:
        return None
    if header[156:157] not in (b"0", b"\0"):
        return None
    return {
        "filename": filename,
        "member": name,
        "size": size,
        "header_sha256": sha256_bytes(header),
        "stored_checksum": stored_checksum,
    }


def find_boundary(identity: dict, target_offset: int, name_to_index: dict[str, int]) -> dict:
    reader = RangeReader(identity["_signed_url"])
    prefix = f"{identity['language']}_{identity['split']}_0/"
    known_names = set(name_to_index)
    offset = max(512, (target_offset // 512) * 512)
    probes = 0
    try:
        while offset + 511 < identity["archive_size"] and probes < 4096:
            header, _ = reader.get(offset, offset + 511)
            probes += 1
            parsed = maybe_tar_header(header, prefix, known_names)
            if parsed is not None:
                return {
                    "offset": offset,
                    "index": name_to_index[parsed["filename"]],
                    "filename": parsed["filename"],
                    "header_sha256": parsed["header_sha256"],
                    "target_offset": target_offset,
                    "probe_count": probes,
                    "probe_bytes": probes * 512,
                }
            offset += 512
    finally:
        reader.close()
    raise RuntimeError(
        f"{identity['archive_path']}: no valid header within 2 MiB after {target_offset}"
    )


def discover_boundaries(identity: dict, ordered_names: list[str]) -> list[dict]:
    name_to_index = {name: index for index, name in enumerate(ordered_names)}
    boundaries = [
        {
            "offset": 512,
            "index": 0,
            "filename": ordered_names[0],
            "target_offset": 512,
            "probe_count": 0,
            "probe_bytes": 0,
        }
    ]
    with ThreadPoolExecutor(max_workers=min(ARCHIVE_SEGMENTS - 1, 16)) as executor:
        futures = [
            executor.submit(
                find_boundary,
                identity,
                identity["archive_size"] * segment // ARCHIVE_SEGMENTS,
                name_to_index,
            )
            for segment in range(1, ARCHIVE_SEGMENTS)
        ]
        for future in as_completed(futures):
            boundaries.append(future.result())
    boundaries.sort(key=lambda item: item["offset"])
    if len(boundaries) != ARCHIVE_SEGMENTS:
        raise RuntimeError(f"{identity['archive_path']}: incomplete boundary discovery")
    if len({item["offset"] for item in boundaries}) != len(boundaries):
        raise RuntimeError(f"{identity['archive_path']}: duplicate boundary offsets")
    indices = [item["index"] for item in boundaries]
    if indices != sorted(indices) or len(set(indices)) != len(indices):
        raise RuntimeError(f"{identity['archive_path']}: boundary filename order mismatch")
    return boundaries


def scan_segment(
    identity: dict,
    ordered_names: list[str],
    start: dict,
    end: dict | None,
    selected_by_name: dict[str, dict],
) -> dict:
    reader = RangeReader(identity["_signed_url"])
    prefix = f"{identity['language']}_{identity['split']}_0/"
    offset = start["offset"]
    index = start["index"]
    end_index = end["index"] if end is not None else len(ordered_names)
    header_chain = hashlib.sha256()
    downloads = []
    try:
        while index < end_index:
            filename = ordered_names[index]
            header, _ = reader.get(offset, offset + 511)
            parsed = validate_tar_header(header, f"{prefix}{filename}", octal_field(header[124:136], "size"))
            size = parsed["size"]
            header_chain.update(offset.to_bytes(8, "little"))
            header_chain.update(header)
            selected_row = selected_by_name.get(filename)
            if selected_row is not None:
                source, _ = reader.get(offset + 512, offset + 511 + size)
                if not (
                    source.startswith(b"ID3")
                    or source.startswith(b"\xff\xfb")
                    or source.startswith(b"\xff\xf3")
                ):
                    raise RuntimeError(f"{filename}: selected TAR payload is not MP3")
                source_path = (
                    SOURCE_ROOT
                    / identity["language"]
                    / identity["split"]
                    / filename
                )
                atomic_bytes(source_path, source)
                downloads.append(
                    {
                        "language": identity["language"],
                        "split": identity["split"],
                        "source_row_index": selected_row["source_row_index"],
                        "source_filename": filename,
                        "source_path": str(source_path),
                        "source_sha256": sha256_bytes(source),
                        "source_size": len(source),
                        "archive_path": identity["archive_path"],
                        "archive_url": identity["archive_url"],
                        "archive_size": identity["archive_size"],
                        "archive_linked_etag": identity["archive_linked_etag"],
                        "archive_linked_etag_sha256": identity["archive_linked_etag_sha256"],
                        "archive_object_etag": identity["archive_object_etag"],
                        "archive_object_etag_sha256": identity["archive_object_etag_sha256"],
                        "archive_member": parsed["member"],
                        "archive_member_header_sha256": parsed["header_sha256"],
                        "archive_member_stored_checksum": parsed["stored_checksum"],
                        "range_start": offset + 512,
                        "range_end": offset + 511 + size,
                        "range_payload_bytes": len(source),
                        "http_status": 206,
                    }
                )
            offset += 512 + math.ceil(size / 512) * 512
            index += 1
    finally:
        reader.close()
    if end is not None and offset != end["offset"]:
        raise RuntimeError(
            f"{identity['archive_path']}: segment ended at {offset}, expected {end['offset']}"
        )
    return {
        "archive_path": identity["archive_path"],
        "start_index": start["index"],
        "end_index": end_index,
        "start_offset": start["offset"],
        "end_offset": offset,
        "member_count": end_index - start["index"],
        "header_chain_sha256": header_chain.hexdigest(),
        "downloads": downloads,
        "is_final_segment": end is None,
    }


def scan_archives(
    selected: list[dict], tables: dict[tuple[str, str], list[dict]]
) -> tuple[dict[tuple[str, str, str], dict], list[dict], list[dict]]:
    identities = {
        (language, split): archive_identity(language, split)
        for language in ("en", "ru")
        for split in ("dev", "test")
    }
    ordered_by_archive = {
        key: sorted((row["path"] for row in rows), key=lambda name: name.encode("utf-8"))
        for key, rows in tables.items()
    }
    selected_by_archive: dict[tuple[str, str], dict[str, dict]] = defaultdict(dict)
    for row in selected:
        selected_by_archive[(row["language"], row["split"])][row["path"]] = row

    all_boundaries = {}
    for key, identity in identities.items():
        print(f"boundary_discovery={identity['archive_path']}", flush=True)
        all_boundaries[key] = discover_boundaries(identity, ordered_by_archive[key])

    futures = {}
    with ThreadPoolExecutor(max_workers=INDEX_WORKERS) as executor:
        for key, identity in identities.items():
            boundaries = all_boundaries[key]
            for position, start in enumerate(boundaries):
                end = boundaries[position + 1] if position + 1 < len(boundaries) else None
                future = executor.submit(
                    scan_segment,
                    identity,
                    ordered_by_archive[key],
                    start,
                    end,
                    selected_by_archive[key],
                )
                futures[future] = (key, position)
        segment_results = []
        completed_count = 0
        for future in as_completed(futures):
            result = future.result()
            segment_results.append(result)
            completed_count += 1
            if completed_count % 4 == 0 or completed_count == len(futures):
                print(f"tar_index_progress={completed_count}/{len(futures)}", flush=True)

    downloads: dict[tuple[str, str, str], dict] = {}
    final_offsets = {}
    for result in segment_results:
        for download in result.pop("downloads"):
            key = (download["language"], download["split"], download["source_filename"])
            if key in downloads:
                raise RuntimeError(f"duplicate selected download: {key}")
            downloads[key] = download
        if result["is_final_segment"]:
            final_offsets[result["archive_path"]] = result["end_offset"]

    archive_records = []
    for key, identity in sorted(identities.items()):
        final_offset = final_offsets.get(identity["archive_path"])
        if final_offset is None or final_offset + 1024 > identity["archive_size"]:
            raise RuntimeError(f"{identity['archive_path']}: invalid computed TAR terminator offset")
        reader = RangeReader(identity["_signed_url"])
        try:
            terminator, _ = reader.get(final_offset, final_offset + 1023)
        finally:
            reader.close()
        if terminator != b"\0" * 1024:
            raise RuntimeError(f"{identity['archive_path']}: missing two-block TAR terminator")
        archive_downloads = [
            item for item in downloads.values() if item["archive_path"] == identity["archive_path"]
        ]
        boundaries = all_boundaries[key]
        archive_records.append(
            {
                **{field: value for field, value in identity.items() if not field.startswith("_")},
                "member_count": len(ordered_by_archive[key]),
                "selected_members": len(archive_downloads),
                "selected_source_bytes": sum(item["source_size"] for item in archive_downloads),
                "directory_header_valid": True,
                "all_member_headers_valid": True,
                "two_block_terminator_valid": True,
                "computed_terminator_offset": final_offset,
                "boundary_count": len(boundaries),
                "boundary_probe_count": sum(item["probe_count"] for item in boundaries),
                "boundary_probe_bytes": sum(item["probe_bytes"] for item in boundaries),
                "boundaries": boundaries,
            }
        )
    return downloads, archive_records, sorted(
        segment_results, key=lambda item: (item["archive_path"], item["start_offset"])
    )


def parse_wave_f32le(path: Path) -> tuple[bytes, dict]:
    value = path.read_bytes()
    if len(value) < 44 or value[:4] != b"RIFF" or value[8:12] != b"WAVE":
        raise RuntimeError(f"{path}: not a RIFF/WAVE file")
    offset = 12
    fmt = None
    data = None
    chunks = []
    while offset + 8 <= len(value):
        chunk_id = value[offset : offset + 4]
        size = struct.unpack_from("<I", value, offset + 4)[0]
        payload_start = offset + 8
        payload_end = payload_start + size
        if payload_end > len(value):
            raise RuntimeError(f"{path}: truncated WAVE chunk")
        chunks.append({"id": chunk_id.decode("latin-1"), "size": size})
        payload = value[payload_start:payload_end]
        if chunk_id == b"fmt ":
            fmt = payload
        elif chunk_id == b"data":
            if data is not None:
                raise RuntimeError(f"{path}: duplicate WAVE data chunk")
            data = payload
        offset = payload_end + (size & 1)
    if fmt is None or len(fmt) < 16 or data is None:
        raise RuntimeError(f"{path}: missing WAVE fmt/data chunk")
    audio_format, channels, rate, byte_rate, block_align, bits = struct.unpack_from("<HHIIHH", fmt, 0)
    if (audio_format, channels, rate, byte_rate, block_align, bits) != (3, 1, 16000, 64000, 4, 32):
        raise RuntimeError(
            f"{path}: unexpected canonical WAVE fmt "
            f"{(audio_format, channels, rate, byte_rate, block_align, bits)}"
        )
    if not data or len(data) % 4:
        raise RuntimeError(f"{path}: invalid Float32 PCM byte length")
    for (sample,) in struct.iter_unpack("<f", data):
        if not math.isfinite(sample):
            raise RuntimeError(f"{path}: non-finite canonical PCM sample")
    return data, {"wave_chunks": chunks, "sample_count": len(data) // 4}


def canonicalize_one(selected_row: dict, download: dict) -> dict:
    language = selected_row["language"]
    split = selected_row["split"]
    filename = selected_row["path"]
    source_path = Path(download["source_path"])
    fixture_stem = f"common-voice-17-dominant-short-{language}-{split}-{selected_row['source_row_index']:05d}-{Path(filename).stem}"
    pcm_path = PCM_ROOT / language / split / f"{fixture_stem}.f32le"
    pcm_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="openramble-cv17-afconvert-") as temporary:
        wave_path = Path(temporary) / "canonical.wav"
        command = [
            str(AFCONVERT),
            str(source_path),
            "-o",
            str(wave_path),
            "-f",
            "WAVE",
            "-d",
            "LEF32@16000",
            "-c",
            "1",
            "-r",
            "127",
            "--src-complexity",
            "bats",
            "--no-filler",
        ]
        completed = subprocess.run(command, check=False, text=True, capture_output=True)
        if completed.returncode != 0:
            raise RuntimeError(f"afconvert failed for {filename}: {completed.stderr.strip()}")
        pcm, wave_info = parse_wave_f32le(wave_path)
    atomic_bytes(pcm_path, pcm)
    sample_count = len(pcm) // 4
    duration_seconds = sample_count / 16000.0
    actual_bin = duration_bin(duration_seconds)
    if actual_bin != selected_row["duration_bin"]:
        raise RuntimeError(
            f"{filename}: canonical PCM bin {actual_bin}/{duration_seconds:.9f}s "
            f"!= frozen {selected_row['duration_bin']}/{selected_row['duration_seconds']:.9f}s"
        )
    return {
        "fixture_id": fixture_stem,
        "pcm_path": str(pcm_path),
        "pcm_f32le_sha256": sha256_bytes(pcm),
        "pcm_size": len(pcm),
        "sample_count": sample_count,
        "duration_seconds": duration_seconds,
        "declared_duration_seconds": selected_row["duration_seconds"],
        "duration_delta_seconds": duration_seconds - selected_row["duration_seconds"],
        "duration_bin": actual_bin,
        **wave_info,
    }


def build_fixture(selected_row: dict, download: dict, canonical: dict) -> dict:
    language = selected_row["language"]
    split = selected_row["split"]
    metadata_path = META / f"{language}-{split}.tsv"
    return {
        "id": canonical["fixture_id"],
        "suite": "common_voice_17_dominant_short_supplement",
        "kind": "real_public_reference_internal_only",
        "scored": True,
        "language": language,
        "language_hint": language,
        "duration_bin": canonical["duration_bin"],
        "duration_seconds": canonical["duration_seconds"],
        "declared_duration_seconds": canonical["declared_duration_seconds"],
        "declared_duration_ms": selected_row["duration_ms"],
        "duration_delta_seconds": canonical["duration_delta_seconds"],
        "sample_rate": 16000,
        "sample_count": canonical["sample_count"],
        "pcm_path": canonical["pcm_path"],
        "pcm_f32le_sha256": canonical["pcm_f32le_sha256"],
        "pcm_size": canonical["pcm_size"],
        "reference": selected_row["reference"],
        "reference_sha256": selected_row["reference_sha256"],
        "raw_reference": selected_row["reference"],
        "raw_reference_sha256": selected_row["reference_sha256"],
        "source": "mozilla-common-voice-17.0-via-unofficial-huggingface-mirror",
        "source_repository": REPOSITORY,
        "source_revision": REVISION,
        "source_config": language,
        "source_split": split,
        "source_row_index": selected_row["source_row_index"],
        "source_filename": selected_row["path"],
        "source_path": download["source_path"],
        "source_sha256": download["source_sha256"],
        "source_size": download["source_size"],
        "source_url": download["archive_url"],
        "source_archive_path": download["archive_path"],
        "source_archive_member": download["archive_member"],
        "source_archive_size": download["archive_size"],
        "source_archive_linked_etag": download["archive_linked_etag"],
        "source_archive_linked_etag_sha256": download["archive_linked_etag_sha256"],
        "source_archive_object_etag": download["archive_object_etag"],
        "source_archive_object_etag_sha256": download["archive_object_etag_sha256"],
        "source_archive_member_header_sha256": download["archive_member_header_sha256"],
        "source_archive_range_start": download["range_start"],
        "source_archive_range_end": download["range_end"],
        "source_audio_encoding": "MPEG Layer III, pinned source bytes",
        "source_transform": "none_complete_utterance",
        "source_metadata_path": str(metadata_path),
        "source_metadata_sha256": EXPECTED_FROZEN_SHA[metadata_path],
        "source_metadata_row_index": selected_row["source_row_index"],
        "source_sentence_id": selected_row["sentence_id"],
        "source_client_id_sha256": selected_row["client_id_sha256"],
        "selection_key_sha256": selected_row["selection_key_sha256"],
        "license": "CC0-1.0 as declared by pinned unofficial mirror",
        "corpus_access": "internal_evaluation_only",
        "mirror_is_unofficial": True,
        "no_trim": True,
        "no_forced_alignment": True,
        "no_transcript_truncation": True,
    }


def assert_unique_hashes(fixtures: list[dict], prior_manifests: list[Path]) -> dict:
    fixture_ids = [fixture["id"] for fixture in fixtures]
    pcm_hashes = [fixture["pcm_f32le_sha256"] for fixture in fixtures]
    if len(fixture_ids) != len(set(fixture_ids)):
        raise RuntimeError("duplicate final fixture ID")
    if len(pcm_hashes) != len(set(pcm_hashes)):
        duplicates = [value for value, count in Counter(pcm_hashes).items() if count > 1]
        raise RuntimeError(f"duplicate final PCM SHA: {duplicates[:5]}")
    supplement = [fixture for fixture in fixtures if fixture.get("mirror_is_unofficial") is True]
    source_hashes = [fixture["source_sha256"] for fixture in supplement]
    if len(source_hashes) != len(set(source_hashes)):
        duplicates = [value for value, count in Counter(source_hashes).items() if count > 1]
        raise RuntimeError(f"duplicate Common Voice source SHA: {duplicates[:5]}")

    excluded_pcm = set()
    exclusion_records = []
    for path in prior_manifests:
        manifest = load_json(path)
        for fixture in manifest["fixtures"]:
            value = fixture.get("pcm_f32le_sha256")
            if value:
                excluded_pcm.add(value)
        exclusion_records.append(
            {
                "path": str(path),
                "sha256": sha256_file(path),
                "fixture_count": len(manifest["fixtures"]),
            }
        )
    overlap = set(pcm_hashes) & excluded_pcm
    if overlap:
        raise RuntimeError(f"final corpus PCM overlaps prior corpus: {len(overlap)}")
    return {
        "manifests": exclusion_records,
        "selected_source_identity_overlap_count": 0,
        "selected_pcm_sha256_overlap_count": 0,
        "unique_prior_pcm_sha256": len(excluded_pcm),
    }


def main() -> None:
    if MANIFEST_PATH.exists():
        raise RuntimeError(f"refusing to overwrite sealed manifest: {MANIFEST_PATH}")
    validate_frozen_inputs()
    selected, tables, _durations = selected_and_split_tables()

    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    print(
        f"stage=remote_tar_index selected=180 segments={ARCHIVE_SEGMENTS * 4} "
        f"workers={INDEX_WORKERS}",
        flush=True,
    )
    downloads, archive_records, segment_records = scan_archives(selected, tables)
    if len(downloads) != 180:
        raise RuntimeError("missing selected downloads")
    source_hashes = [item["source_sha256"] for item in downloads.values()]
    if len(source_hashes) != len(set(source_hashes)):
        raise RuntimeError("duplicate selected source bytes")
    if {item["archive_path"] for item in archive_records} != {
        "audio/en/dev/en_dev_0.tar",
        "audio/en/test/en_test_0.tar",
        "audio/ru/dev/ru_dev_0.tar",
        "audio/ru/test/ru_test_0.tar",
    }:
        raise RuntimeError("unexpected archive set")
    archive_index = {
        "schema_version": 1,
        "repository": REPOSITORY,
        "revision": REVISION,
        "access": "anonymous pinned HTTP byte ranges",
        "full_archives_not_downloaded": True,
        "selected_complete_source_files_retained": 180,
        "nonselected_complete_source_files_retained": 0,
        "tar_layout": {
            "format": "ustar",
            "initial_directory_header_bytes": 512,
            "member_order": "bytewise lexical filename order",
            "source_sizes": "read from and validated against actual pinned ustar headers",
            "validation": (
                "every member header/name/order/size/checksum was validated; segment boundaries "
                "cross-checked exact offsets; only frozen selected member payloads were retained"
            ),
        },
        "archives": archive_records,
        "segments": segment_records,
    }
    atomic_json(ARCHIVE_INDEX_PATH, archive_index)

    print("stage=canonicalize selected=180 workers=4", flush=True)
    canonicals: dict[tuple[str, str, str], dict] = {}
    with ThreadPoolExecutor(max_workers=CONVERT_WORKERS) as executor:
        futures = {}
        for row in selected:
            key = (row["language"], row["split"], row["path"])
            futures[executor.submit(canonicalize_one, row, downloads[key])] = row
        completed_count = 0
        for future in as_completed(futures):
            row = futures[future]
            key = (row["language"], row["split"], row["path"])
            canonicals[key] = future.result()
            completed_count += 1
            if completed_count % 10 == 0 or completed_count == len(selected):
                with PRINT_LOCK:
                    print(f"canonicalize_progress={completed_count}/180", flush=True)
    if len(canonicals) != 180:
        raise RuntimeError("missing canonical PCM")

    supplement_fixtures = []
    for row in selected:
        key = (row["language"], row["split"], row["path"])
        supplement_fixtures.append(build_fixture(row, downloads[key], canonicals[key]))
    core_manifest = load_json(CORE_MANIFEST_PATH)
    core_fixtures = core_manifest["fixtures"]
    if len(core_fixtures) != 24:
        raise RuntimeError("frozen FLEURS core must contain 24 fixtures")
    fixtures = core_fixtures + supplement_fixtures
    fixtures.sort(key=lambda fixture: fixture["id"])

    prior_manifests = [
        Path("$TMP/openramble-short-quality-gate/corpus/manifest.json"),
        Path("$TMP/openramble-intermediate-quality-gate/corpus/manifest.json"),
    ]
    exclusions = assert_unique_hashes(fixtures, prior_manifests)
    counts = Counter((fixture["language"], fixture["duration_bin"]) for fixture in fixtures)
    expected_final_counts = {
        (language, bin_name): 34
        for language in ("en", "ru")
        for bin_name in ("1-2", "2-3", "3-4")
    }
    if dict(counts) != expected_final_counts:
        raise RuntimeError(f"final language/bin counts mismatch: {counts}")

    source_bytes = sum(item["source_size"] for item in downloads.values())
    selected_payload_bytes = sum(item["range_payload_bytes"] for item in downloads.values())
    range_payload_bytes = int(NETWORK_STATS["cdn_response_body_bytes"])
    full_archive_bytes = sum(record["archive_size"] for record in archive_records)
    download_receipt = {
        "schema_version": 1,
        "status": "complete_sparse_remote_tar_index_selected_sources_only",
        "selected_file_count": 180,
        "selected_source_bytes": source_bytes,
        "selected_payload_range_bytes": selected_payload_bytes,
        "validated_archive_member_count": sum(record["member_count"] for record in archive_records),
        "unique_tar_member_header_bytes": sum(
            record["member_count"] * 512 for record in archive_records
        ),
        "boundary_probe_bytes": sum(record["boundary_probe_bytes"] for record in archive_records),
        "range_payload_bytes": range_payload_bytes,
        "redirect_response_body_bytes": int(NETWORK_STATS["redirect_response_body_bytes"]),
        "total_http_response_body_bytes": (
            range_payload_bytes + int(NETWORK_STATS["redirect_response_body_bytes"])
        ),
        "full_archive_bytes_not_downloaded": full_archive_bytes,
        "body_byte_fraction_vs_full_archives": range_payload_bytes / full_archive_bytes,
        "nonselected_complete_source_files_retained": 0,
        "nonselected_source_payload_bytes_retained": 0,
        "cdn_range_requests": int(NETWORK_STATS["cdn_requests"]),
        "redirect_requests": int(NETWORK_STATS["redirect_requests"]),
        "cdn_non_206_responses": int(NETWORK_STATS["cdn_non_206_responses"]),
        "revision": REVISION,
        "archive_index": str(ARCHIVE_INDEX_PATH),
        "archive_index_sha256": sha256_file(ARCHIVE_INDEX_PATH),
    }
    atomic_json(DOWNLOAD_RECEIPT_PATH, download_receipt)

    afconvert_version = subprocess.run(
        [str(AFCONVERT), "-h"], check=False, text=True, capture_output=True
    ).stdout.splitlines()[:3]
    canonicalizer = {
        "schema_version": 1,
        "tool": str(AFCONVERT),
        "tool_sha256": sha256_file(AFCONVERT),
        "afinfo_sha256": sha256_file(AFINFO),
        "macos": subprocess.run(
            ["/usr/bin/sw_vers"], check=True, text=True, capture_output=True
        ).stdout.strip().splitlines(),
        "version_banner": afconvert_version,
        "command_template": [
            "/usr/bin/afconvert",
            "SOURCE.mp3",
            "-o",
            "TEMP.wav",
            "-f",
            "WAVE",
            "-d",
            "LEF32@16000",
            "-c",
            "1",
            "-r",
            "127",
            "--src-complexity",
            "bats",
            "--no-filler",
        ],
        "wave_extraction": "extract RIFF data chunk byte-for-byte after validating IEEE Float32 mono 16kHz fmt",
        "output": "headerless mono 16000-Hz IEEE-754 Float32 little-endian",
        "transform": "decode and sample-rate/channel conversion only; no trim, forced alignment, VAD, padding, or transcript transform",
        "finite_sample_validation": True,
    }
    atomic_json(CANONICALIZER_PATH, canonicalizer)

    source_index = "".join(
        f"{fixture['source_sha256']}  {fixture['source_path']}\n"
        for fixture in sorted(fixtures, key=lambda item: item["source_path"])
    )
    pcm_index = "".join(
        f"{fixture['pcm_f32le_sha256']}  {fixture['pcm_path']}\n"
        for fixture in sorted(fixtures, key=lambda item: item["pcm_path"])
    )
    reference_index = "".join(
        f"{fixture['reference_sha256']}  {fixture['id']}\n"
        for fixture in sorted(fixtures, key=lambda item: item["id"])
    )
    atomic_text(SOURCE_INDEX_PATH, source_index)
    atomic_text(PCM_INDEX_PATH, pcm_index)
    atomic_text(REFERENCE_INDEX_PATH, reference_index)

    manifest = {
        "schema_version": 1,
        "corpus_id": "openramble-dominant-short-quality-v1",
        "status": "sealed_before_inference",
        "inference_allowed": True,
        "model_outputs_inspected": False,
        "scope": "internal_evaluation_only_unofficial_mirror",
        "distribution_allowed": False,
        "warning": (
            "Internal evaluation corpus. Common Voice clips were obtained from the pinned "
            "unofficial fsicoli mirror; do not redistribute this assembled corpus."
        ),
        "sources": {
            "fleurs_core": {
                "repository": "google/fleurs",
                "revision": "70bb2e84b976b7e960aa89f1c648e09c59f894dd",
                "license": "CC BY 4.0",
                "manifest": str(CORE_MANIFEST_PATH),
                "manifest_sha256": sha256_file(CORE_MANIFEST_PATH),
                "fixtures": 24,
            },
            "common_voice_supplement": {
                "upstream_release": "Mozilla Common Voice Corpus 17.0",
                "upstream_license_declared_by_mirror": "CC0-1.0",
                "repository": REPOSITORY,
                "revision": REVISION,
                "mirror_is_unofficial": True,
                "internal_evaluation_only": True,
                "readme": str(AUDIT_ROOT / "README.md"),
                "readme_sha256": sha256_file(AUDIT_ROOT / "README.md"),
                "selection_plan": str(SELECTION_PATH),
                "selection_plan_sha256": sha256_file(SELECTION_PATH),
                "fixtures": 180,
            },
        },
        "canonicalization": {
            "record": str(CANONICALIZER_PATH),
            "record_sha256": sha256_file(CANONICALIZER_PATH),
            "format": "f32le",
            "sample_rate": 16000,
            "channels": 1,
            "trim": False,
            "forced_alignment": False,
            "transcript_truncation": False,
        },
        "download": {
            **download_receipt,
            "receipt": str(DOWNLOAD_RECEIPT_PATH),
            "receipt_sha256": sha256_file(DOWNLOAD_RECEIPT_PATH),
        },
        "frozen_inputs": [
            {"path": str(path), "sha256": expected}
            for path, expected in sorted(EXPECTED_FROZEN_SHA.items(), key=lambda item: str(item[0]))
        ],
        "indices": {
            "source": str(SOURCE_INDEX_PATH),
            "source_sha256": sha256_file(SOURCE_INDEX_PATH),
            "pcm": str(PCM_INDEX_PATH),
            "pcm_sha256": sha256_file(PCM_INDEX_PATH),
            "reference": str(REFERENCE_INDEX_PATH),
            "reference_sha256": sha256_file(REFERENCE_INDEX_PATH),
            "archive": str(ARCHIVE_INDEX_PATH),
            "archive_sha256": sha256_file(ARCHIVE_INDEX_PATH),
        },
        "counts": {
            "fixtures": len(fixtures),
            "en": sum(fixture["language"] == "en" for fixture in fixtures),
            "ru": sum(fixture["language"] == "ru" for fixture in fixtures),
            "common_voice": len(supplement_fixtures),
            "fleurs": len(core_fixtures),
            "unique_fixture_ids": len({fixture["id"] for fixture in fixtures}),
            "unique_pcm_sha256": len({fixture["pcm_f32le_sha256"] for fixture in fixtures}),
            "unique_common_voice_source_sha256": len(
                {fixture["source_sha256"] for fixture in supplement_fixtures}
            ),
            "by_language_duration_bin": {
                language: {
                    bin_name: counts[(language, bin_name)]
                    for bin_name in ("1-2", "2-3", "3-4")
                }
                for language in ("en", "ru")
            },
        },
        "exclusions": exclusions,
        "fail_closed_checks": {
            "missing_files": 0,
            "duplicate_fixture_ids": 0,
            "duplicate_pcm_sha256": 0,
            "duplicate_common_voice_source_sha256": 0,
            "source_hash_mismatches": 0,
            "pcm_hash_mismatches": 0,
            "reference_hash_mismatches": 0,
            "locale_mismatches": 0,
            "duration_bin_mismatches": 0,
            "tar_header_or_member_mismatches": 0,
            "prior_pcm_overlaps": 0,
            "forbidden_trim_or_alignment_transforms": 0,
        },
        "asr_or_coreml_runs": 0,
        "fixtures": fixtures,
    }
    atomic_json(MANIFEST_PATH, manifest)
    print(f"final_manifest={MANIFEST_PATH}", flush=True)
    print(f"final_manifest_sha256={sha256_file(MANIFEST_PATH)}", flush=True)
    print(f"selected_source_bytes={source_bytes}", flush=True)
    print(f"range_payload_bytes={range_payload_bytes}", flush=True)
    print(f"fixtures={len(fixtures)}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL_CLOSED: {error}", file=sys.stderr, flush=True)
        raise
