#!/usr/bin/env python3
"""Fail-closed, CPU-only verification for the sealed SenseVoice checkpoint.

This script never downloads artifacts, loads an MLModel, or invokes inference.
The only probe executions exercise authorization/manifest failures before the
first model-load call is reachable.
"""

from __future__ import annotations

import collections
import copy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import subprocess
import sys
import tempfile
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
FLUID = ROOT / "FluidAudio"
BINARY = ROOT / ".build/release/sensevoice-probe"
SHARED = Path("$REPO")
TINY_SOURCE = Path("$TMP/openramble-real-short-manifest.json")
CORPUS_SOURCE = Path(
    "$TMP/openramble-dominant-short-quality-v1/final-corpus/manifest.json"
)
PRODUCT_CONFIG = Path("$TMP/openramble-intermediate-quality-gate/PRODUCT_CONFIG.json")

EXPECTED_OPENRAMBLE = "f2b6e8cc66d20f7a07094f79af0faf3ba861af64"
EXPECTED_FLUID = "ee9a7f12d91710da53de6d75f8b7160e09eccee4"
EXPECTED_UPSTREAM_TAG = "19600a485baa4998812e4654b70d2bab8f2c9949"
EXPECTED_SENSEVOICE_TREE = "97d7b4a569390fc7a1baae947e6b7f27e0c8c331"
EXPECTED_MODEL_REVISION = "cdea3526163035c19915d4a10268992d018ebd46"
EXPECTED_MODEL_MANIFEST_SHA256 = (
    "d0a99130a53b09b6756b1203eb057d197608f278913f7aace3ce1a71b00e7906"
)
EXPECTED_TINY_SOURCE_SHA256 = (
    "1143305176fc436795395019f0051d8db8670d691f7c6470a81f4d872b79470c"
)
EXPECTED_CORPUS_SHA256 = (
    "340314c63357f2ec0bcb4091438a71b43668ecba4ad376dc8844e9785d86faf6"
)
EXPECTED_PRODUCT_CONFIG_SHA256 = (
    "98338d07767b45d3abaf222a790b6070b4a0dae6291343034cd7b91f16f3c59b"
)
HEX64 = re.compile(r"^[0-9a-f]{64}$")


class CheckFailure(RuntimeError):
    pass


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise CheckFailure(detail)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def strict_json_bytes(data: bytes) -> Any:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise CheckFailure(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    try:
        return json.loads(data, object_pairs_hook=reject_duplicates)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise CheckFailure(f"invalid JSON: {error}") from error


def strict_json_file(path: Path) -> Any:
    return strict_json_bytes(path.read_bytes())


def git(args: list[str], directory: Path) -> str:
    completed = subprocess.run(
        ["git", *args], cwd=directory, check=True, text=True, capture_output=True
    )
    return completed.stdout.strip()


def validate_manifest_structure(manifest: Any) -> None:
    require(type(manifest) is dict, "model manifest must be an object")
    require(manifest.get("schema_version") == 1, "unexpected model manifest schema")
    require(
        manifest.get("repository") == "FluidInference/sensevoice-small-coreml",
        "unexpected model repository",
    )
    require(manifest.get("revision") == EXPECTED_MODEL_REVISION, "unexpected model revision")
    require(manifest.get("precision") == "int8", "unexpected precision")
    require(manifest.get("compute_units") == "cpuAndNeuralEngine", "unexpected compute route")
    artifacts = manifest.get("artifacts")
    require(type(artifacts) is list and len(artifacts) == 9, "expected exactly 9 artifacts")
    seen: set[str] = set()
    total = 0
    for index, artifact in enumerate(artifacts):
        require(type(artifact) is dict, f"artifact {index} must be an object")
        path = artifact.get("path")
        size = artifact.get("byte_count")
        digest = artifact.get("sha256")
        require(type(path) is str and path != "", f"artifact {index} has invalid path")
        pure = PurePosixPath(path)
        require(not pure.is_absolute() and ".." not in pure.parts, f"unsafe artifact path: {path}")
        require(path not in seen, f"duplicate artifact path: {path}")
        seen.add(path)
        require(type(size) is int and size >= 0, f"invalid byte count: {path}")
        require(type(digest) is str and HEX64.fullmatch(digest) is not None, f"invalid SHA: {path}")
        total += size
    require(total == 239_913_642, f"artifact sum mismatch: {total}")
    require(manifest.get("total_byte_count") == total, "declared artifact total mismatch")


def verify_model_manifest() -> dict[str, Any]:
    path = ROOT / "MODEL_ARTIFACTS.json"
    observed_sha = sha256_file(path)
    require(observed_sha == EXPECTED_MODEL_MANIFEST_SHA256, "model manifest SHA mismatch")
    manifest = strict_json_file(path)
    validate_manifest_structure(manifest)
    return {
        "sha256": observed_sha,
        "artifact_count": len(manifest["artifacts"]),
        "selected_bytes": manifest["total_byte_count"],
    }


def verify_git_pins() -> dict[str, Any]:
    pins = strict_json_file(ROOT / "PINS.json")
    require(git(["rev-parse", "HEAD"], SHARED) == EXPECTED_OPENRAMBLE, "shared HEAD moved")
    require(git(["status", "--porcelain"], SHARED) == "", "shared repository is dirty")
    require(git(["rev-parse", "HEAD"], FLUID) == EXPECTED_FLUID, "Fluid HEAD mismatch")
    require(git(["status", "--porcelain"], FLUID) == "", "Fluid worktree is dirty")
    subprocess.run(
        ["git", "merge-base", "--is-ancestor", EXPECTED_UPSTREAM_TAG, EXPECTED_FLUID],
        cwd=FLUID,
        check=True,
    )
    relative_tree = "Sources/FluidAudio/ASR/SenseVoice"
    fork_tree = git(["rev-parse", f"{EXPECTED_FLUID}:{relative_tree}"], FLUID)
    tag_tree = git(["rev-parse", f"{EXPECTED_UPSTREAM_TAG}:{relative_tree}"], FLUID)
    require(fork_tree == EXPECTED_SENSEVOICE_TREE == tag_tree, "SenseVoice source tree mismatch")
    source_blobs = pins["fluid_audio"]["source_blobs"]
    source_paths = {
        "SenseVoiceConfig.swift": f"{relative_tree}/SenseVoiceConfig.swift",
        "SenseVoiceModels.swift": f"{relative_tree}/SenseVoiceModels.swift",
        "SenseVoiceManager.swift": f"{relative_tree}/SenseVoiceManager.swift",
        "ModelNames.swift": "Sources/FluidAudio/ModelNames.swift",
        "LICENSE": "LICENSE",
    }
    for name, relative_path in source_paths.items():
        observed = git(["rev-parse", f"HEAD:{relative_path}"], FLUID)
        require(observed == source_blobs[name], f"source blob mismatch: {name}")
    require(
        sha256_file(FLUID / "LICENSE") == pins["fluid_audio"]["license"]["text_sha256"],
        "Fluid license text mismatch",
    )
    return {
        "openramble_head": EXPECTED_OPENRAMBLE,
        "fluid_head": EXPECTED_FLUID,
        "sensevoice_tree": fork_tree,
        "shared_clean": True,
        "fluid_clean": True,
    }


def verify_source_semantics() -> dict[str, Any]:
    manager = (FLUID / "Sources/FluidAudio/ASR/SenseVoice/SenseVoiceManager.swift").read_text()
    models = (FLUID / "Sources/FluidAudio/ASR/SenseVoice/SenseVoiceModels.swift").read_text()
    config = (FLUID / "Sources/FluidAudio/ASR/SenseVoice/SenseVoiceConfig.swift").read_text()
    package = (FLUID / "Package.swift").read_text()
    runner = (ROOT / "Sources/SenseVoiceProbe/main.swift").read_text()
    required_manager = [
        "public func transcribe(audio: [Float]) throws -> String",
        "models.preprocessor.prediction(from: input)",
        "models.encoder.prediction(from: input)",
        r'replacingOccurrences(of: "<\\|[^|]*\\|>"',
    ]
    for needle in required_manager:
        require(needle in manager, f"missing manager semantic anchor: {needle}")
    require("timestamp" not in manager.lower(), "unexpected timestamp API appeared")
    require("confidence" not in manager.lower(), "unexpected confidence API appeared")
    require("candidateRegions" not in manager, "unexpected vocabulary candidateRegions API appeared")
    for needle in [
        "self == .fp32 ? .all : .cpuAndNeuralEngine",
        "cpuConfig.computeUnits = .cpuOnly",
        "public static func load(",
        "public static func downloadAndLoad(",
    ]:
        require(needle in models, f"missing model semantic anchor: {needle}")
    require("public static let buckets = [128, 256, 512, 1024, 1800]" in config, "bucket drift")
    require(".macOS(.v14)" in package, "declared macOS floor drift")
    token_position = runner.index("try consumeOneUseToken")
    manifest_position = runner.index("let manifestData = try Data")
    offline_position = runner.index("ModelHub.offlineMode = true")
    local_load_position = runner.index("let models = try SenseVoiceModels.load(from:")
    require(token_position < manifest_position < offline_position < local_load_position, "runner gate order drift")
    require(EXPECTED_MODEL_MANIFEST_SHA256 in runner, "runner does not hard-pin model manifest")
    require("SenseVoiceManager.load(" not in runner, "runner reaches downloading manager load")
    require("SenseVoiceModels.downloadAndLoad(" not in runner, "runner reaches downloading model load")
    require("minimumModelSamples = 3_200" in runner, "minimum input bound missing")
    require("maximumModelSamples = 480_000" in runner, "maximum input bound missing")
    return {
        "fluid_result_type": "String",
        "word_timings": False,
        "confidence": False,
        "candidate_regions": False,
        "runner_manifest_hard_pin": True,
        "runner_offline_before_local_load": True,
        "preprocessor_sample_range": [3200, 480000],
    }


def wav_sample_identity(path: Path) -> tuple[int, int, int, int]:
    data = path.read_bytes()
    require(len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WAVE", f"not WAV: {path}")
    offset = 12
    fmt: tuple[int, int, int, int] | None = None
    data_size: int | None = None
    while offset + 8 <= len(data):
        chunk_id = data[offset : offset + 4]
        size = struct.unpack_from("<I", data, offset + 4)[0]
        start = offset + 8
        end = start + size
        require(end <= len(data), f"truncated WAV chunk: {path}")
        if chunk_id == b"fmt ":
            require(size >= 16, f"short WAV fmt: {path}")
            audio_format, channels, rate, _, block_align, bits = struct.unpack_from("<HHIIHH", data, start)
            require(audio_format in (1, 3, 0xFFFE), f"unsupported WAV format {audio_format}: {path}")
            fmt = (channels, rate, block_align, bits)
        elif chunk_id == b"data":
            data_size = size
        offset = end + (size & 1)
    require(fmt is not None and data_size is not None, f"missing WAV fmt/data: {path}")
    channels, rate, block_align, bits = fmt
    require(block_align > 0 and data_size % block_align == 0, f"invalid WAV alignment: {path}")
    return channels, rate, bits, data_size // block_align


def verify_tiny() -> dict[str, Any]:
    require(sha256_file(TINY_SOURCE) == EXPECTED_TINY_SOURCE_SHA256, "tiny source manifest changed")
    prereg = strict_json_file(ROOT / "TINY_SMOKE_PREREG.json")
    source = strict_json_file(TINY_SOURCE)
    require(prereg["status"].endswith("blocked_by_source_capability_gate"), "tiny gate is not blocked")
    fixtures = prereg["fixtures"]
    require(len(fixtures) == 4, "tiny fixture count drift")
    source_by_id = {fixture["id"]: fixture for fixture in source["fixtures"]}
    require(len(source_by_id) == 4, "tiny source fixture count drift")
    for fixture in fixtures:
        require(fixture["id"] in source_by_id, f"tiny source missing {fixture['id']}")
        path = Path(fixture["path"])
        require(path.is_file(), f"tiny fixture missing: {path}")
        require(sha256_file(path) == fixture["sha256"], f"tiny fixture SHA mismatch: {path}")
        require(source_by_id[fixture["id"]]["sha256"] == fixture["sha256"], "tiny manifest mismatch")
        channels, rate, _, samples = wav_sample_identity(path)
        require(channels == 1 and rate == 16000, f"tiny audio format mismatch: {path}")
        require(samples == fixture["sample_count"], f"tiny sample count mismatch: {path}")
        require(abs(samples / rate - fixture["duration_seconds"]) < 0.000_001, "tiny duration drift")
    requests = [
        strict_json_bytes(line)
        for line in (ROOT / "TINY_CANDIDATE_REQUESTS.jsonl").read_bytes().splitlines()
        if line.strip()
    ]
    require(requests[-1] == {"command": "shutdown", "id": "shutdown"}, "shutdown not final")
    load_index = next(index for index, request in enumerate(requests) if request["command"] == "load")
    preloads = [request for request in requests[:load_index] if request["command"] == "preload"]
    require(len(preloads) == 4 and load_index == 4, "fixtures must be verified before model load")
    expected = {fixture["id"]: fixture for fixture in fixtures}
    for request in preloads:
        fixture = expected[request["key"]]
        require(request["source_sha256"] == fixture["sha256"], "request source SHA mismatch")
        require(request["sample_count"] == fixture["sample_count"], "request sample count mismatch")
    runs = [request for request in requests if request["command"] == "run"]
    require(len(runs) == 16, "tiny measured run count drift")
    require(sum(request["language"] == "en" for request in runs) == 8, "EN route count drift")
    require(sum(request["language"] == "auto" for request in runs) == 8, "RU diagnostic count drift")
    return {
        "source_manifest_sha256": EXPECTED_TINY_SOURCE_SHA256,
        "fixture_count": 4,
        "measured_candidate_runs": 16,
        "fixtures_verified_before_model_load": True,
    }


def verify_corpus() -> dict[str, Any]:
    require(sha256_file(CORPUS_SOURCE) == EXPECTED_CORPUS_SHA256, "204 corpus manifest changed")
    prereg = strict_json_file(ROOT / "CORPUS_204_PREREG.json")
    corpus = strict_json_file(CORPUS_SOURCE)
    require(prereg["status"] == "sealed_and_blocked_before_candidate_inference", "204 gate unsealed")
    require(corpus["asr_or_coreml_runs"] == 0, "corpus manifest records prior model runs")
    fixtures = corpus["fixtures"]
    require(len(fixtures) == 204, "204 fixture count drift")
    language_counts: collections.Counter[str] = collections.Counter()
    bin_counts: collections.Counter[tuple[str, str]] = collections.Counter()
    total_seconds = 0.0
    total_pcm_bytes = 0
    seen_ids: set[str] = set()
    seen_pcm_hashes: set[str] = set()
    for fixture in fixtures:
        fixture_id = fixture["id"]
        require(fixture_id not in seen_ids, f"duplicate corpus fixture id: {fixture_id}")
        seen_ids.add(fixture_id)
        language = fixture["language"]
        duration_bin = fixture["duration_bin"]
        language_counts[language] += 1
        bin_counts[(language, duration_bin)] += 1
        require(fixture["sample_rate"] == 16000, f"sample-rate drift: {fixture_id}")
        pcm_path = Path(fixture["pcm_path"])
        require(pcm_path.is_file(), f"missing corpus PCM: {pcm_path}")
        size = pcm_path.stat().st_size
        require(size == fixture["sample_count"] * 4, f"PCM size drift: {fixture_id}")
        require(size == fixture.get("pcm_size", size), f"declared PCM size drift: {fixture_id}")
        observed_sha = sha256_file(pcm_path)
        require(observed_sha == fixture["pcm_f32le_sha256"], f"PCM SHA drift: {fixture_id}")
        require(observed_sha not in seen_pcm_hashes, f"duplicate PCM identity: {fixture_id}")
        seen_pcm_hashes.add(observed_sha)
        total_seconds += fixture["duration_seconds"]
        total_pcm_bytes += size
    require(language_counts == {"en": 102, "ru": 102}, f"language counts drift: {language_counts}")
    for language in ("en", "ru"):
        for duration_bin in ("1-2", "2-3", "3-4"):
            require(bin_counts[(language, duration_bin)] == 34, "duration-bin count drift")
    require(abs(total_seconds - 547.184125) < 0.000_001, f"corpus duration drift: {total_seconds}")
    require(sha256_file(PRODUCT_CONFIG) == EXPECTED_PRODUCT_CONFIG_SHA256, "product config changed")
    product = strict_json_file(PRODUCT_CONFIG)
    require(product["vocabulary"]["enabled"] is True, "shipping vocabulary disabled")
    require(product["vocabulary"]["scheduling"] == "candidateRegions", "vocab scheduler drift")
    require(product["vocabulary"]["terms"] == 28, "vocabulary term count drift")
    return {
        "manifest_sha256": EXPECTED_CORPUS_SHA256,
        "fixture_count": len(fixtures),
        "languages": dict(language_counts),
        "pcm_bytes_hashed": total_pcm_bytes,
        "total_audio_seconds": total_seconds,
        "shipping_product_config_sha256": EXPECTED_PRODUCT_CONFIG_SHA256,
    }


def invoke_probe(binary: Path, token: Path, expected_token_sha: str, model_dir: Path) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update(
        {
            "REGISTRY_URL": "http://127.0.0.1:9",
            "MODEL_REGISTRY_URL": "http://127.0.0.1:9",
            "https_proxy": "http://127.0.0.1:9",
            "http_proxy": "http://127.0.0.1:9",
        }
    )
    return subprocess.run(
        [
            str(binary),
            "server",
            "--model-dir",
            str(model_dir),
            "--artifact-manifest",
            str(ROOT / "MODEL_ARTIFACTS.json"),
            "--token-file",
            str(token),
            "--token-sha256",
            expected_token_sha,
        ],
        input="",
        text=True,
        capture_output=True,
        env=environment,
        timeout=15,
        check=False,
    )


def verify_probe_authorization() -> dict[str, Any]:
    require(BINARY.is_file() and os.access(BINARY, os.X_OK), "release probe missing")
    secret = b"deterministic-cpu-only-authorization-test\n"
    correct_sha = hashlib.sha256(secret).hexdigest()
    with tempfile.TemporaryDirectory(prefix="sensevoice-cpu-token-") as temporary:
        directory = Path(temporary)
        model_dir = directory / "empty-model"
        model_dir.mkdir()

        wrong_mode = directory / "wrong-mode.token"
        wrong_mode.write_bytes(secret)
        wrong_mode.chmod(0o644)
        result = invoke_probe(BINARY, wrong_mode, correct_sha, model_dir)
        require(result.returncode == 64 and wrong_mode.exists(), "wrong-mode token did not fail closed")
        require("mode must be 0600" in result.stderr, "wrong-mode rejection reason drift")

        wrong_hash = directory / "wrong-hash.token"
        wrong_hash.write_bytes(secret)
        wrong_hash.chmod(0o600)
        result = invoke_probe(BINARY, wrong_hash, "0" * 64, model_dir)
        require(result.returncode == 64 and wrong_hash.exists(), "wrong-hash token did not fail closed")
        require("token SHA-256 mismatch" in result.stderr, "wrong-hash rejection reason drift")

        accepted = directory / "accepted.token"
        accepted.write_bytes(secret)
        accepted.chmod(0o600)
        result = invoke_probe(BINARY, accepted, correct_sha, model_dir)
        require(result.returncode == 64 and not accepted.exists(), "accepted token was not consumed")
        require("artifact is missing" in result.stderr, "empty model did not fail before model load")
        require(result.stdout == "", "failure path emitted protocol output")
    return {
        "wrong_mode_retained": True,
        "wrong_hash_retained": True,
        "accepted_token_consumed": True,
        "accepted_token_stopped_at_missing_artifact_before_model_load": True,
        "binary_sha256": sha256_file(BINARY),
        "binary_bytes": BINARY.stat().st_size,
    }


def verify_downloader_guard() -> dict[str, Any]:
    script = ROOT / "scripts/download_exact_int8.sh"
    require(script.is_file(), "exact downloader missing")
    subprocess.run(["/bin/bash", "-n", str(script)], check=True)
    text = script.read_text()
    require(EXPECTED_MODEL_REVISION in text, "downloader revision drift")
    require("/resolve/main/" not in text, "downloader uses mutable main")
    require("239913642" in text, "downloader total drift")
    destination = Path("$TMP/openramble-sensevoice-model-cpu-guard-test")
    require(not destination.exists(), "guard-test destination unexpectedly exists")
    environment = os.environ.copy()
    environment.pop("OPENRAMBLE_SENSEVOICE_WEIGHT_DOWNLOAD_GO", None)
    result = subprocess.run(
        [str(script), str(destination)], text=True, capture_output=True, env=environment, check=False
    )
    require(result.returncode == 64, "downloader ran without explicit GO")
    require(not destination.exists(), "downloader guard mutated destination")
    return {"syntax": "PASS", "no_go_exit": 64, "no_go_files_created": True}


def verify_static_ru_gate() -> dict[str, Any]:
    pins = strict_json_file(ROOT / "PINS.json")
    upstream = pins["upstream_checkpoint"]
    require("ru" not in upstream["official_released_asr_languages"], "released language list gained RU")
    require(upstream["runtime_has_ru_hint"] is False, "runtime unexpectedly gained RU hint")
    require("ru" not in upstream["runtime_lid_map"], "runtime LID map unexpectedly gained RU")
    require(upstream["fluid_vocab_contains_ru_tag"] is True, "RU metadata tag evidence drift")
    require(upstream["fluid_vocab_cyrillic_piece_count"] == 0, "Cyrillic tokenizer evidence drift")
    require(upstream["fluid_vocab_byte_fallback_piece_count"] == 0, "byte-fallback evidence drift")
    return {
        "official_released_languages": upstream["official_released_asr_languages"],
        "runtime_ru_hint": False,
        "cyrillic_token_pieces": 0,
        "byte_fallback_token_pieces": 0,
        "decision": "HARD_NO_EN_RU",
    }


def main() -> int:
    checks: dict[str, Any] = {}
    try:
        checks["model_manifest"] = verify_model_manifest()
        checks["git_pins"] = verify_git_pins()
        checks["source_semantics"] = verify_source_semantics()
        checks["static_ru_gate"] = verify_static_ru_gate()
        checks["tiny"] = verify_tiny()
        checks["corpus_204"] = verify_corpus()
        checks["probe_authorization"] = verify_probe_authorization()
        checks["downloader_guard"] = verify_downloader_guard()
    except (CheckFailure, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(json.dumps({"status": "FAIL", "error": str(error)}, sort_keys=True), file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "status": "PASS",
                "scope": "CPU/source only; no model load, inference, or weight download",
                "checks": checks,
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
