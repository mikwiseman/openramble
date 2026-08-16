#!/usr/bin/env python3
"""Archive the August 2026 ASR research session without committing private payloads.

The research used many isolated /private/tmp worktrees. This collector preserves
their small, reviewable source/evidence files, all dirty Git patches, and a full
metadata-only file inventory. It deliberately excludes model weights, compiled
products, audio, traces, build caches, credentials, and corpus payloads.
"""

from __future__ import annotations

import csv
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Iterable


REPO = Path(__file__).resolve().parents[1]
TMP = Path("/private/tmp")
DEST = REPO / "research" / "asr-performance-2026-08"
MAX_ARCHIVED_FILE_BYTES = 5 * 1024 * 1024

ROOT_PREFIXES = ("openramble", "nemotron", "OpenRamble")
EXTRA_ROOTS = {
    "nemo-speech-source-only-audit-9bc876635af3.md",
}

TEXT_SUFFIXES = {
    "", ".c", ".cc", ".cpp", ".csv", ".diff", ".h", ".hpp", ".json",
    ".jsonl", ".log", ".m", ".md", ".mil", ".mm", ".patch", ".plist",
    ".py", ".rs", ".sh", ".stderr", ".stdout", ".swift", ".toml", ".ts",
    ".tsv", ".txt", ".xml", ".yaml", ".yml",
}

FORBIDDEN_COMPONENTS = {
    ".build", ".git", "DerivedData", "Models", "SourcePackages", "__pycache__",
    "build", "build-debug", "build-tsan", "checkouts", "compiled",
    "compiled-hybrid-compact", "node_modules", "target", "uv-cache", "weights",
}

FORBIDDEN_SUFFIXES = {
    ".a", ".bin", ".dmg", ".dSYM", ".f32le", ".gguf", ".gz", ".ips",
    ".mlmodelc", ".mlpackage", ".nemo", ".o", ".pcm", ".png", ".so",
    ".tar", ".trace", ".wav", ".xcarchive", ".zip", ".zst",
}

# Whole-system process snapshots can expose unrelated application command lines.
# They are not needed to reproduce the scoped worker lifecycle assertions.
FORBIDDEN_BASENAMES = {"pre-ps.txt", "post-ps.txt"}
FORBIDDEN_CONTAINER_SUFFIXES = (".dSYM", ".mlmodelc", ".mlpackage", ".xcarchive")

# Safe trees whose source and small evidence files are worth preserving directly.
TREE_SOURCES = {
    "openramble-canonical-endpoint-v1.QLyMSY": ["."],
    "openramble-dual-cache-falsifier": ["."],
    "openramble-dual-cache-model-preflight": ["harness"],
    "openramble-encoder-4bit": ["."],
    "openramble-endpoint-cache": ["harness"],
    "openramble-fused-tdt-cached": ["smoke", "artifacts/export"],
    "openramble-gpu-cache-parity-ee9a7f12": ["harness"],
    "openramble-intermediate-quality-gate": ["reports", "scripts"],
    "openramble-nemotron-coreml-smoke": ["."],
    "openramble-phase-breakdown-ee9a7f12": ["harness", "reports"],
    "openramble-sensevoice-source-checkpoint": ["Sources", "Tests", "scripts"],
    "openramble-short-quality-gate": ["reports"],
    "openramble-short-shape": ["harness", "reports"],
    "openramble-speech-analyzer-probe": ["."],
    "openramble-static12_5-no-vocab-fallback-v1": ["."],
    "openramble-stop-precompute-ee9a7f12": ["Sources"],
    "openramble-streaming-tdt-audit-ee9a7f12": ["."],
}

# Exact high-value files from large roots. Globs are relative to /private/tmp.
CURATED_GLOBS = [
    "nemo-speech-source-only-audit-9bc876635af3.md",
    "nemotron35-stage1.*/R6_STAGE1_HARD_STOP.md",
    "openramble-architecture-review-20260814.md",
    "openramble-asr-candidate-audit-f2b6ee9a/{MEMO.md,EVIDENCE_SHA256.txt,SEALED_SHA256.txt}",
    "openramble-asr-worker-soak-10000-final.json",
    "openramble-asr-worker-soak-final-secure.json",
    "openramble-asr-worker-soak-tsan-final.json",
    "openramble-benchmark-v3-resume-smoke.json",
    "openramble-benchmark-v3-smoke.json",
    "openramble-cache-*.tsv",
    "openramble-cache-reset-*.json",
    "openramble-ctc-*-20260814.json",
    "openramble-ctc-evaluation-profile.json",
    "openramble-ctc-fusion-profile.json",
    "openramble-derived-overlay-installer-memo.md",
    "openramble-direct-*-20260814.json",
    "openramble-dominant-short-quality-v1/*.md",
    "openramble-dominant-short-quality-v1/*.json",
    "openramble-dominant-short-quality-v1/*.py",
    "openramble-encoder-4bit/EVIDENCE.md",
    "openramble-fair-n50-manifest.json",
    "openramble-fair-paired-n50-20260814-evidence.json",
    "openramble-fair-paired-n50-20260814.json",
    "openramble-fused-tdt-cached/*.json",
    "openramble-fused-tdt-cached/*.log",
    "openramble-gpu-cache-parity-ee9a7f12/*.json",
    "openramble-gpu-cache-parity-ee9a7f12/*.log",
    "openramble-gpu-cache-parity-ee9a7f12/EVIDENCE.md",
    "openramble-int8-encoder-e2c2449/EVIDENCE.md",
    "openramble-int8-encoder-e2c2449/results/*.json",
    "openramble-intermediate-quality-gate/*.md",
    "openramble-intermediate-quality-gate/*.json",
    "openramble-intermediate-quality-gate/reports/**/*.md",
    "openramble-intermediate-quality-gate/reports/**/*.json",
    "openramble-jointdecision-auto-aed0274/*.json",
    "openramble-jointdecision-auto-aed0274/*.log",
    "openramble-jointdecision-auto-aed0274/EVIDENCE.md",
    "openramble-jointdecisionv2-aed0274/*.md",
    "openramble-jointdecisionv2-aed0274/*.json",
    "openramble-kimi-*.md",
    "openramble-kimi-*.prompt",
    "openramble-kimi-*.txt",
    "openramble-nemotron-coreml-model-api.json",
    "openramble-nemotron-coreml-smoke/EVIDENCE.md",
    "openramble-nemotron-coreml-smoke/smoke-report.json",
    "openramble-phase-breakdown-ee9a7f12/*.md",
    "openramble-phase-breakdown-ee9a7f12/*.json",
    "openramble-phase-term-*.json",
    "openramble-phase-timing-m4-20260814.json",
    "openramble-sensevoice-source-checkpoint/*.json",
    "openramble-sensevoice-source-checkpoint/*.jsonl",
    "openramble-sensevoice-source-checkpoint/*.md",
    "openramble-sensevoice-source-checkpoint/Package.swift",
    "openramble-short-engine.SpfSeY/REPORT.md",
    "openramble-short-quality-gate/reports/**/*.md",
    "openramble-short-quality-gate/reports/**/*.json",
    "openramble-short-shape/*.md",
    "openramble-short-shape/*.json",
    "openramble-short-shape/*.py",
    "openramble-short-shape/reports/**/*.json",
    "openramble-speech-analyzer-probe/*.md",
    "openramble-speech-analyzer-probe/*.json",
    "openramble-speech-analyzer-probe/*.swift",
    "openramble-static12_5-no-vocab-fallback-v1/*",
    "openramble-stop-precompute-ee9a7f12/*.md",
    "openramble-stop-precompute-ee9a7f12/*.json",
    "openramble-stop-precompute-ee9a7f12/*.py",
    "openramble-streaming-tdt-audit-ee9a7f12/*",
    "openramble-two-or-ab.py",
]

REDACTIONS = {
    str(REPO): "$REPO",
    str(Path.home()): "$HOME",
    str(TMP): "$TMP",
}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sanitize_text(data: bytes) -> tuple[bytes, bool]:
    if b"\0" in data:
        raise ValueError("binary content")
    text = data.decode("utf-8")
    original = text
    for source, replacement in REDACTIONS.items():
        text = text.replace(source, replacement)
    # Keep generated evidence friendly to `git diff --check`. Original hashes
    # remain in the manifest, so this normalization never obscures provenance.
    lines = [line.rstrip() for line in text.splitlines()]
    while lines and not lines[-1]:
        lines.pop()
    text = "\n".join(lines)
    if text:
        text += "\n"
    return text.encode("utf-8"), text != original


def safe_source(path: Path) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    if path.name in FORBIDDEN_BASENAMES:
        return False
    if any(part.startswith(".build") for part in path.parts):
        return False
    if any(part.endswith(FORBIDDEN_CONTAINER_SUFFIXES) for part in path.parts):
        return False
    if path.stat().st_size > MAX_ARCHIVED_FILE_BYTES:
        return False
    if any(part in FORBIDDEN_COMPONENTS for part in path.parts):
        return False
    if path.suffix in FORBIDDEN_SUFFIXES:
        return False
    return path.suffix in TEXT_SUFFIXES


def logical_path(path: Path) -> str:
    try:
        return "$TMP/" + str(path.relative_to(TMP))
    except ValueError:
        return str(path)


def archive_file(source: Path, relative_dest: Path, manifest: list[dict]) -> None:
    if not safe_source(source):
        return
    original = source.read_bytes()
    try:
        archived, redacted = sanitize_text(original)
    except (UnicodeDecodeError, ValueError):
        return
    target = DEST / "evidence" / relative_dest
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(archived)
    manifest.append({
        "source": logical_path(source),
        "archived": str(target.relative_to(REPO)),
        "original_bytes": len(original),
        "archived_bytes": len(archived),
        "original_sha256": sha256_bytes(original),
        "archived_sha256": sha256_bytes(archived),
        "redacted_local_paths": redacted,
    })


def expand_braces(pattern: str) -> Iterable[str]:
    if "{" not in pattern:
        yield pattern
        return
    prefix, rest = pattern.split("{", 1)
    options, suffix = rest.split("}", 1)
    for option in options.split(","):
        yield prefix + option + suffix


def temp_roots() -> list[Path]:
    roots = []
    for path in TMP.iterdir():
        if path.name.startswith(ROOT_PREFIXES) or path.name in EXTRA_ROOTS:
            roots.append(path)
    return sorted(roots, key=lambda item: item.name)


def walk_files(root: Path) -> Iterable[Path]:
    if root.is_file():
        yield root
        return
    for directory, names, files in os.walk(root, followlinks=False):
        names[:] = [name for name in names if name not in FORBIDDEN_COMPONENTS]
        for name in files:
            yield Path(directory) / name


def collect_curated(manifest: list[dict]) -> None:
    seen: set[Path] = set()
    for raw_pattern in CURATED_GLOBS:
        for pattern in expand_braces(raw_pattern):
            for source in TMP.glob(pattern):
                if source in seen:
                    continue
                seen.add(source)
                if source.is_file():
                    archive_file(source, Path("curated") / source.relative_to(TMP), manifest)
    for root_name, subpaths in TREE_SOURCES.items():
        root = TMP / root_name
        if not root.exists():
            continue
        for subpath in subpaths:
            source_root = root / subpath
            if not source_root.exists():
                continue
            for source in walk_files(source_root):
                if source in seen:
                    continue
                seen.add(source)
                archive_file(source, Path("trees") / source.relative_to(TMP), manifest)


def run_git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args], text=True, capture_output=True, check=False
    )
    return result.stdout.strip()


def discover_git_repos(roots: list[Path]) -> list[Path]:
    repos: set[Path] = set()
    for root in roots:
        if not root.is_dir():
            continue
        root_depth = len(root.parts)
        for directory, names, _files in os.walk(root, followlinks=False):
            current = Path(directory)
            if len(current.parts) - root_depth > 5:
                names[:] = []
                continue
            if ".git" in names or (current / ".git").is_file():
                repos.add(current)
                names[:] = [name for name in names if name != ".git"]
    return sorted(repos)


def collect_git_state(roots: list[Path], manifest: list[dict]) -> None:
    git_root = DEST / "source-patches"
    for index, repo in enumerate(discover_git_repos(roots), start=1):
        slug = f"{index:02d}-" + str(repo.relative_to(TMP)).replace("/", "__")
        destination = git_root / slug
        destination.mkdir(parents=True, exist_ok=True)
        metadata = {
            "source": logical_path(repo),
            "head": run_git(repo, "rev-parse", "HEAD"),
            "branch": run_git(repo, "branch", "--show-current"),
            "origin": run_git(repo, "remote", "get-url", "origin"),
            "status": run_git(repo, "status", "--short", "--untracked-files=all").splitlines(),
        }
        metadata_bytes, _ = sanitize_text(
            (json.dumps(metadata, indent=2, sort_keys=True) + "\n").encode()
        )
        metadata_path = destination / "metadata.json"
        metadata_path.write_bytes(metadata_bytes)

        patch = run_git(repo, "diff", "--no-ext-diff", "--no-textconv")
        if patch:
            patch_bytes, _ = sanitize_text((patch + "\n").encode())
            (destination / "changes.patch").write_bytes(patch_bytes)

        stat = run_git(repo, "diff", "--stat")
        if stat:
            stat_bytes, _ = sanitize_text((stat + "\n").encode())
            (destination / "changes.stat.txt").write_bytes(stat_bytes)

        for line in metadata["status"]:
            if not line.startswith("?? "):
                continue
            untracked = repo / line[3:]
            if safe_source(untracked):
                archive_file(
                    untracked,
                    Path("untracked-git") / slug / untracked.relative_to(repo),
                    manifest,
                )


def collect_inventory(roots: list[Path]) -> None:
    inventory_path = DEST / "manifests" / "TEMP_ROOT_INVENTORY.tsv"
    inventory_path.parent.mkdir(parents=True, exist_ok=True)
    with inventory_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(["logical_path", "kind", "bytes", "mtime_epoch", "preservation"])
        for root in roots:
            if root.is_file():
                size = root.stat().st_size
                kind = "file"
            else:
                result = subprocess.run(
                    ["du", "-sk", str(root)], text=True, capture_output=True, check=False
                )
                size = int(result.stdout.split()[0]) * 1024 if result.stdout else -1
                kind = "directory"
            preservation = "curated-content+metadata" if root.name in TREE_SOURCES else "metadata-or-selected-evidence"
            writer.writerow([
                logical_path(root), kind, size, int(root.stat().st_mtime), preservation,
            ])

    all_files_path = DEST / "manifests" / "ALL_TEMP_FILE_PATHS.tsv.gz"
    with gzip.GzipFile(filename="", mode="wb", fileobj=all_files_path.open("wb"), mtime=0) as raw:
        header = "logical_path\tbytes\tmtime_epoch\n".encode()
        raw.write(header)
        for root in roots:
            for path in walk_files(root):
                try:
                    stat = path.stat()
                except FileNotFoundError:
                    continue
                row = f"{logical_path(path)}\t{stat.st_size}\t{int(stat.st_mtime)}\n"
                raw.write(row.encode("utf-8", errors="backslashreplace"))


def write_manifest(manifest: list[dict]) -> None:
    manifest.sort(key=lambda item: item["archived"])
    path = DEST / "manifests" / "ARCHIVED_CONTENT.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        "schema_version": 1,
        "source_root": "$TMP",
        "max_archived_file_bytes": MAX_ARCHIVED_FILE_BYTES,
        "entries": manifest,
    }, indent=2, sort_keys=True) + "\n")


def main() -> int:
    if not TMP.is_dir():
        print("/private/tmp is unavailable", file=sys.stderr)
        return 2
    if DEST.exists():
        shutil.rmtree(DEST / "evidence", ignore_errors=True)
        shutil.rmtree(DEST / "source-patches", ignore_errors=True)
        shutil.rmtree(DEST / "manifests", ignore_errors=True)
    DEST.mkdir(parents=True, exist_ok=True)
    roots = temp_roots()
    manifest: list[dict] = []
    collect_inventory(roots)
    collect_curated(manifest)
    collect_git_state(roots, manifest)
    write_manifest(manifest)
    print(json.dumps({
        "temp_roots": len(roots),
        "archived_files": len(manifest),
        "destination": str(DEST),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
