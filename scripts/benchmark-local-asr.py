#!/usr/bin/env python3
"""Paired, persistent local-ASR benchmark for OpenRamble and Handy.

The default lane times only recognition of an already decoded 16 kHz mono
Float32 buffer. OpenRamble exports that canonical f32le buffer and every engine
must confirm its SHA-256 before measurements begin. WAV decoding is available
as the explicitly separate ``file-wall`` lane.

Handy comparison requires a locally built JSONL benchmark adapter. It is not an
official Handy application benchmark and this runner never labels it as one.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import selectors
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from random import Random
from typing import Any, Iterable


SCHEMA_VERSION = 3
PROTOCOL_VERSION = 1
HEX_64 = re.compile(r"^[0-9a-f]{64}$")
HEX_40 = re.compile(r"^[0-9a-f]{40}$")
ENGINE_ORDER = {"OH": ("openramble", "handy"), "HO": ("handy", "openramble")}


def arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run a deterministic paired benchmark against persistent JSONL engines. "
            "The default measures predecoded in-memory recognition; it does not "
            "measure process launch, model load, or WAV decoding."
        )
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        required=True,
        help=(
            "fixture manifest with id, absolute path, and sha256 for every input; "
            "Handy comparisons also require a language per fixture"
        ),
    )
    parser.add_argument(
        "--openramble-bin",
        type=Path,
        default=Path("Packages/LocalASR/.build/release/asr-bench"),
        help="asr-bench executable; launched once with serve-jsonl",
    )
    parser.add_argument(
        "--handy-bin",
        type=Path,
        help=(
            "locally built Handy JSONL adapter binary (not an official app-parity lane); "
            "requires all --handy-* provenance arguments"
        ),
    )
    parser.add_argument("--handy-model", help="exact Handy model registry id")
    parser.add_argument(
        "--handy-model-path",
        type=Path,
        help="exact model file/directory loaded by the Handy adapter",
    )
    parser.add_argument(
        "--handy-model-sha256",
        help="expected SHA-256 (or deterministic tree SHA-256) of --handy-model-path",
    )
    parser.add_argument(
        "--handy-source-commit",
        help="40-character Handy source commit used for the local adapter build",
    )
    parser.add_argument(
        "--handy-patch",
        type=Path,
        help="patch applied to the pinned Handy source to add the JSONL adapter",
    )
    parser.add_argument("--handy-device-index", type=int)
    parser.add_argument(
        "--repeats",
        type=int,
        default=100,
        help="measured pairs per fixture and engine (default: 100; must be even)",
    )
    parser.add_argument(
        "--warmups",
        type=int,
        default=6,
        help="unreported paired fixture warm-ups (default: 6; must be even)",
    )
    parser.add_argument(
        "--lane",
        choices=("predecoded-product-warm", "file-wall"),
        default="predecoded-product-warm",
        help=(
            "predecoded-product-warm times only transcribe(samples:) (default); "
            "file-wall separately times each engine's file decode plus recognition"
        ),
    )
    parser.add_argument("--seed", type=int, default=20260814)
    parser.add_argument(
        "--bootstrap-samples",
        type=int,
        default=10_000,
        help="paired bootstrap resamples for 95%% confidence intervals",
    )
    parser.add_argument(
        "--openramble-vocabulary", choices=("on", "off"), default="on"
    )
    parser.add_argument(
        "--openramble-prewarm", choices=("on", "off"), default="on"
    )
    parser.add_argument(
        "--openramble-encoder-placement",
        choices=("automatic", "gpu", "neuralEngine"),
        default="automatic",
    )
    parser.add_argument(
        "--openramble-vocabulary-scheduling",
        choices=("candidateRegions", "alwaysParallel"),
        default="candidateRegions",
    )
    parser.add_argument("--openramble-language")
    parser.add_argument("--openramble-vocabulary-terms", type=int)
    parser.add_argument("--timeout-seconds", type=float, default=1800)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--resume",
        action="store_true",
        help="resume only if every experiment identity hash still matches",
    )
    return parser.parse_args(argv)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def path_fingerprint(path: Path) -> dict[str, Any]:
    if path.is_symlink():
        raise ValueError(f"refusing symlink as benchmark identity: {path}")
    path = path.resolve()
    if path.is_file():
        return {"kind": "file", "sha256": sha256(path), "byte_count": path.stat().st_size}
    if not path.is_dir():
        raise ValueError(f"model path does not exist: {path}")
    entries: list[dict[str, Any]] = []
    for candidate in sorted(path.rglob("*"), key=lambda item: item.relative_to(path).as_posix()):
        if candidate.is_symlink():
            raise ValueError(f"refusing symlink inside model identity: {candidate}")
        if not candidate.is_file():
            continue
        relative = candidate.relative_to(path).as_posix()
        entries.append(
            {
                "path": relative,
                "byte_count": candidate.stat().st_size,
                "sha256": sha256(candidate),
            }
        )
    if not entries:
        raise ValueError(f"model directory contains no files: {path}")
    canonical = b"".join(
        (
            entry["path"].encode("utf-8")
            + b"\0"
            + str(entry["byte_count"]).encode("ascii")
            + b"\0"
            + entry["sha256"].encode("ascii")
            + b"\n"
        )
        for entry in entries
    )
    return {
        "kind": "directory",
        "sha256": hashlib.sha256(canonical).hexdigest(),
        "byte_count": sum(item["byte_count"] for item in entries),
        "file_count": len(entries),
        "files": entries,
    }


def canonical_json_hash(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def percentile(values: Iterable[float | int], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("cannot calculate a percentile of no samples")
    if len(ordered) == 1:
        return float(ordered[0])
    position = fraction * (len(ordered) - 1)
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return float(ordered[lower]) * (1 - weight) + float(ordered[upper]) * weight


def summarize_ns(values: list[int], audio_duration_ns: int) -> dict[str, Any]:
    median = float(statistics.median(values))
    return {
        "runs_ns": values,
        "minimum_ns": min(values),
        "p50_ns": median,
        "p95_ns": percentile(values, 0.95),
        "p99_ns": percentile(values, 0.99),
        "maximum_ns": max(values),
        "p50_seconds": median / 1_000_000_000,
        "p95_seconds": percentile(values, 0.95) / 1_000_000_000,
        "p99_seconds": percentile(values, 0.99) / 1_000_000_000,
        "maximum_seconds": max(values) / 1_000_000_000,
        "p50_realtime_factor": audio_duration_ns / median,
    }


def words(text: str) -> list[str]:
    return re.findall(r"[\w']+", text.casefold(), flags=re.UNICODE)


def transcript_fingerprints(text: str) -> dict[str, str]:
    normalized = " ".join(words(text))
    return {
        "raw_transcript_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        "normalized_transcript_sha256": hashlib.sha256(
            normalized.encode("utf-8")
        ).hexdigest(),
    }


def word_error_rate(reference: str | None, hypothesis: str) -> float | None:
    if reference is None:
        return None
    expected = words(reference)
    actual = words(hypothesis)
    if not expected:
        return 0.0 if not actual else 1.0
    previous = list(range(len(actual) + 1))
    for row, expected_word in enumerate(expected, start=1):
        current = [row]
        for column, actual_word in enumerate(actual, start=1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[column] + 1,
                    previous[column - 1] + (expected_word != actual_word),
                )
            )
        previous = current
    return previous[-1] / len(expected)


def derived_seed(seed: int, *parts: str) -> int:
    payload = "\0".join([str(seed), *parts]).encode("utf-8")
    return int.from_bytes(hashlib.sha256(payload).digest()[:8], "big")


def balanced_schedule(count: int, seed: int, fixture_id: str, phase: str) -> list[str]:
    if count <= 0 or count % 2:
        raise ValueError("balanced paired schedules require a positive even count")
    schedule = ["OH"] * (count // 2) + ["HO"] * (count // 2)
    Random(derived_seed(seed, fixture_id, phase)).shuffle(schedule)
    return schedule


def paired_bootstrap(
    openramble: list[int],
    handy: list[int],
    samples: int,
    seed: int,
) -> dict[str, Any]:
    if len(openramble) != len(handy) or not openramble:
        raise ValueError("paired bootstrap needs two equally sized non-empty samples")
    if samples < 100:
        raise ValueError("paired bootstrap needs at least 100 resamples")
    rng = Random(seed)
    count = len(openramble)
    ratios: list[float] = []
    deltas: list[float] = []
    for _ in range(samples):
        indices = [rng.randrange(count) for _ in range(count)]
        open_sample = [openramble[index] for index in indices]
        handy_sample = [handy[index] for index in indices]
        open_median = float(statistics.median(open_sample))
        handy_median = float(statistics.median(handy_sample))
        ratios.append(handy_median / open_median)
        deltas.append(float(statistics.median([h - o for o, h in zip(open_sample, handy_sample)])))
    point_open = float(statistics.median(openramble))
    point_handy = float(statistics.median(handy))
    pair_deltas = [h - o for o, h in zip(openramble, handy)]
    return {
        "resamples": samples,
        "confidence": 0.95,
        "handy_over_openramble_p50_ratio": point_handy / point_open,
        "handy_over_openramble_p50_ratio_ci": [
            percentile(ratios, 0.025),
            percentile(ratios, 0.975),
        ],
        "paired_median_delta_ns": float(statistics.median(pair_deltas)),
        "paired_median_delta_ns_ci": [
            percentile(deltas, 0.025),
            percentile(deltas, 0.975),
        ],
    }


class JSONLProcess:
    def __init__(
        self,
        name: str,
        command: list[str],
        environment: dict[str, str],
        timeout_seconds: float,
    ) -> None:
        self.name = name
        self.command = command
        self.timeout_seconds = timeout_seconds
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            # Both engines may log recognized text at debug level. Never retain
            # their stderr: protocol failures are structured on stdout.
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            bufsize=1,
            env=environment,
        )
        if self.process.stdin is None or self.process.stdout is None:
            raise RuntimeError(f"{name}: failed to create JSONL pipes")
        self.next_id = 1

    def request(
        self,
        command: str,
        *,
        timeout_seconds: float | None = None,
        **payload: Any,
    ) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        request = {"id": request_id, "command": command, **payload}
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        try:
            self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise RuntimeError(f"{self.name}: request pipe closed during {command}") from error

        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        timeout = self.timeout_seconds if timeout_seconds is None else timeout_seconds
        ready = selector.select(timeout)
        selector.close()
        if not ready:
            raise TimeoutError(f"{self.name}: {command} exceeded {timeout:.1f}s")
        line = self.process.stdout.readline()
        if not line:
            code = self.process.poll()
            raise RuntimeError(f"{self.name}: EOF during {command} (exit={code})")
        try:
            response = json.loads(line)
        except json.JSONDecodeError as error:
            raise RuntimeError(f"{self.name}: non-JSON protocol output: {line[:200]!r}") from error
        if not isinstance(response, dict):
            raise RuntimeError(f"{self.name}: response is not an object")
        if response.get("id") != request_id:
            raise RuntimeError(
                f"{self.name}: response id {response.get('id')!r} != request id {request_id}"
            )
        if response.get("protocol_version") != PROTOCOL_VERSION:
            raise RuntimeError(f"{self.name}: unsupported protocol version")
        if response.get("ok") is not True:
            raise RuntimeError(f"{self.name}: {command} failed: {response.get('error', 'unknown error')}")
        return response

    def close(self) -> None:
        if self.process.poll() is None:
            try:
                self.request("shutdown", timeout_seconds=2)
            except (OSError, RuntimeError, TimeoutError):
                pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)

    def __enter__(self) -> "JSONLProcess":
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def sysctl(name: str) -> str | None:
    try:
        return subprocess.check_output(["sysctl", "-n", name], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def host_identity() -> dict[str, Any]:
    return {
        "machine": platform.machine(),
        "macos": platform.mac_ver()[0],
        "chip": sysctl("machdep.cpu.brand_string"),
        "memory_bytes": int(sysctl("hw.memsize") or 0) or None,
        "python": platform.python_version(),
    }


def validate_hex(value: str | None, pattern: re.Pattern[str], label: str) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise ValueError(f"{label} has the wrong format")
    return value


def validate_arguments(args: argparse.Namespace) -> None:
    if args.repeats < 2 or args.repeats % 2:
        raise ValueError("--repeats must be an even number of at least 2")
    if args.warmups < 2 or args.warmups % 2:
        raise ValueError("--warmups must be an even number of at least 2")
    if args.bootstrap_samples < 100:
        raise ValueError("--bootstrap-samples must be at least 100")
    if args.timeout_seconds <= 0:
        raise ValueError("--timeout-seconds must be positive")
    if args.openramble_vocabulary_terms is not None and args.openramble_vocabulary_terms <= 0:
        raise ValueError("--openramble-vocabulary-terms must be positive")
    if not args.openramble_bin.is_file():
        raise ValueError(f"OpenRamble binary does not exist: {args.openramble_bin}")
    if not os.access(args.openramble_bin, os.X_OK):
        raise ValueError(f"OpenRamble binary is not executable: {args.openramble_bin}")

    handy_values = [
        args.handy_bin,
        args.handy_model,
        args.handy_model_path,
        args.handy_model_sha256,
        args.handy_source_commit,
        args.handy_patch,
    ]
    if any(value is not None for value in handy_values):
        if not all(value is not None for value in handy_values):
            raise ValueError(
                "Handy comparison requires --handy-bin, --handy-model, --handy-model-path, "
                "--handy-model-sha256, --handy-source-commit, and --handy-patch"
            )
        assert args.handy_bin is not None
        assert args.handy_model_path is not None
        assert args.handy_patch is not None
        if not args.handy_bin.is_file():
            raise ValueError(f"Handy adapter binary does not exist: {args.handy_bin}")
        if not os.access(args.handy_bin, os.X_OK):
            raise ValueError(f"Handy adapter binary is not executable: {args.handy_bin}")
        if not args.handy_model_path.exists():
            raise ValueError(f"Handy model path does not exist: {args.handy_model_path}")
        if not args.handy_patch.is_file():
            raise ValueError(f"Handy adapter patch does not exist: {args.handy_patch}")
        validate_hex(args.handy_source_commit, HEX_40, "--handy-source-commit")
        validate_hex(args.handy_model_sha256, HEX_64, "--handy-model-sha256")


def load_manifest(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise ValueError("manifest must contain a non-empty fixtures array")
    seen: set[str] = set()
    for fixture in fixtures:
        if not isinstance(fixture, dict):
            raise ValueError("every fixture must be an object")
        fixture_id = fixture.get("id")
        raw_path = fixture.get("path")
        expected_hash = fixture.get("sha256")
        if not isinstance(fixture_id, str) or not fixture_id:
            raise ValueError("every fixture requires a non-empty string id")
        if fixture_id in seen:
            raise ValueError(f"duplicate fixture id: {fixture_id}")
        seen.add(fixture_id)
        if not isinstance(raw_path, str) or not Path(raw_path).is_absolute():
            raise ValueError(f"{fixture_id}: path must be absolute")
        fixture_path = Path(raw_path)
        if not fixture_path.is_file():
            raise ValueError(f"{fixture_id}: fixture does not exist: {fixture_path}")
        validate_hex(expected_hash, HEX_64, f"{fixture_id}.sha256")
        actual = sha256(fixture_path)
        if actual != expected_hash:
            raise ValueError(f"{fixture_id}: fixture SHA-256 does not match manifest")
    return manifest, fixtures


def openramble_environment(args: argparse.Namespace) -> dict[str, str]:
    environment = os.environ.copy()
    for key in (
        "WAI_VOCAB",
        "WAI_VOCAB_DIR",
        "WAI_ASR_PREWARM",
        "WAI_ASR_ENCODER_PLACEMENT",
        "WAI_ASR_VOCAB_SCHEDULING",
        "WAI_ASR_LANGUAGE",
        "WAI_VOCAB_TERMS",
    ):
        environment.pop(key, None)
    if args.openramble_vocabulary == "on":
        environment["WAI_VOCAB"] = "on"
    environment["WAI_ASR_ENCODER_PLACEMENT"] = args.openramble_encoder_placement
    environment["WAI_ASR_VOCAB_SCHEDULING"] = args.openramble_vocabulary_scheduling
    if args.openramble_language:
        environment["WAI_ASR_LANGUAGE"] = args.openramble_language
    if args.openramble_vocabulary_terms is not None:
        environment["WAI_VOCAB_TERMS"] = str(args.openramble_vocabulary_terms)
    return environment


def static_load_identity(response: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in response.items()
        if key not in {"id", "ok", "command", "load_ns"}
    }


def reported_model_fingerprints(identity: dict[str, Any]) -> dict[str, Any]:
    fingerprints: dict[str, Any] = {}
    for key in ("model", "vocabulary_model"):
        model = identity.get(key)
        if not isinstance(model, dict):
            fingerprints[key] = None
            continue
        directory = model.get("engine_directory")
        if not isinstance(directory, str):
            raise ValueError(f"OpenRamble load response omitted {key}.engine_directory")
        fingerprints[key] = path_fingerprint(Path(directory))
    return fingerprints


def validate_openramble_identity(
    identity: dict[str, Any], requested: dict[str, Any]
) -> None:
    effective = identity.get("effective_settings")
    if not isinstance(effective, dict):
        raise ValueError("OpenRamble load response omitted effective settings")
    expected = {
        "vocabulary_enabled": requested["vocabulary"],
        "encoder_placement": requested["encoder_placement"],
        "vocabulary_scheduling": requested["vocabulary_scheduling"],
        "language": requested["language"],
    }
    if requested["vocabulary_terms"] is not None:
        expected["vocabulary_terms"] = requested["vocabulary_terms"]
    mismatches = {
        key: {"expected": value, "reported": effective.get(key)}
        for key, value in expected.items()
        if effective.get(key) != value
    }
    if mismatches:
        raise ValueError(
            "OpenRamble effective settings differ from request: "
            + json.dumps(mismatches, sort_keys=True)
        )


def sanitize_observation(
    response: dict[str, Any],
    reference: str | None,
    expected_pcm_hash: str | None,
    expected_language: str | None,
    require_language_echo: bool,
) -> dict[str, Any]:
    elapsed = response.get("elapsed_ns")
    text = response.get("text")
    if isinstance(elapsed, bool) or not isinstance(elapsed, int) or elapsed <= 0:
        raise RuntimeError("engine returned a non-positive integer elapsed_ns")
    if not isinstance(text, str):
        raise RuntimeError("engine omitted transcript text")
    fingerprints = transcript_fingerprints(text)
    engine_raw_hash = response.get("raw_transcript_sha256")
    if engine_raw_hash != fingerprints["raw_transcript_sha256"]:
        raise RuntimeError("engine raw transcript hash does not match its transcript")
    engine_normalized_hash = response.get("normalized_transcript_sha256")
    validate_hex(
        engine_normalized_hash,
        HEX_64,
        "engine normalized transcript SHA-256",
    )
    language_override = response.get("language_override")
    if require_language_echo and language_override != expected_language:
        raise RuntimeError("Handy adapter did not apply the requested fixture language")
    pcm_hash = response.get("pcm_f32le_sha256")
    validate_hex(pcm_hash, HEX_64, "engine PCM SHA-256")
    if expected_pcm_hash is not None and pcm_hash != expected_pcm_hash:
        raise RuntimeError("engine transcribed a different canonical PCM buffer")
    return {
        "elapsed_ns": elapsed,
        "pcm_f32le_sha256": pcm_hash,
        **fingerprints,
        "engine_normalized_transcript_sha256": response.get(
            "normalized_transcript_sha256"
        ),
        "language_override": (
            language_override if require_language_echo else expected_language
        ),
        "word_error_rate": word_error_rate(reference, text),
        "sample_count": response.get("sample_count"),
        "sample_rate": response.get("sample_rate"),
        "prewarmed": response.get("prewarmed"),
        "peak_rss_bytes": response.get("peak_rss_bytes"),
    }


def execute_observation(
    engine: JSONLProcess,
    engine_name: str,
    lane: str,
    fixture: dict[str, Any],
    expected_pcm_hash: str | None,
) -> dict[str, Any]:
    language = fixture.get("language")
    if lane == "predecoded-product-warm":
        response = engine.request("run", key=fixture["id"], language=language)
    else:
        response = engine.request("run-file", path=fixture["path"], language=language)
    return sanitize_observation(
        response,
        fixture.get("reference"),
        expected_pcm_hash,
        language,
        engine_name == "handy",
    )


def fixture_summary(
    item: dict[str, Any], bootstrap_samples: int, seed: int
) -> dict[str, Any]:
    pairs = item["pairs"]
    audio_duration_ns = item["canonical_pcm"]["audio_duration_ns"]
    engines = ["openramble"] + (["handy"] if pairs and "handy" in pairs[0] else [])
    summary: dict[str, Any] = {}
    for engine in engines:
        observations = [pair[engine] for pair in pairs]
        values = [observation["elapsed_ns"] for observation in observations]
        normalized = [
            observation["normalized_transcript_sha256"] for observation in observations
        ]
        raw = [observation["raw_transcript_sha256"] for observation in observations]
        wers = [
            observation["word_error_rate"]
            for observation in observations
            if observation["word_error_rate"] is not None
        ]
        summary[engine] = {
            **summarize_ns(values, audio_duration_ns),
            "unique_raw_transcripts": len(set(raw)),
            "unique_normalized_transcripts": len(set(normalized)),
            "transcript_stable": len(set(normalized)) == 1,
            "word_error_rate": statistics.median(wers) if wers else None,
            "maximum_peak_rss_bytes": max(
                (value for value in (obs["peak_rss_bytes"] for obs in observations) if isinstance(value, int)),
                default=None,
            ),
            "by_order": {
                order: summarize_ns(
                    [pair[engine]["elapsed_ns"] for pair in pairs if pair["order"] == order],
                    audio_duration_ns,
                )
                for order in ("OH", "HO")
                if any(pair["order"] == order for pair in pairs)
            },
        }

    if "handy" in engines:
        open_values = [pair["openramble"]["elapsed_ns"] for pair in pairs]
        handy_values = [pair["handy"]["elapsed_ns"] for pair in pairs]
        summary["paired_comparison"] = paired_bootstrap(
            open_values,
            handy_values,
            bootstrap_samples,
            derived_seed(seed, item["id"], "bootstrap"),
        )
        summary["paired_comparison"].update(
            {
                "all_normalized_transcripts_equal": all(
                    pair["openramble"]["normalized_transcript_sha256"]
                    == pair["handy"]["normalized_transcript_sha256"]
                    for pair in pairs
                ),
                "openramble_quality_non_inferior": _quality_non_inferior(summary),
                "interpretation": (
                    "ratio > 1 means OpenRamble had the lower p50; this is a local "
                    "patched-backend comparison, not official Handy app parity"
                ),
            }
        )
    return summary


def _quality_non_inferior(summary: dict[str, Any]) -> bool | None:
    open_wer = summary["openramble"]["word_error_rate"]
    handy_wer = summary["handy"]["word_error_rate"]
    if open_wer is None or handy_wer is None:
        return None
    return open_wer <= handy_wer


def safe_filename(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-")
    return cleaned or hashlib.sha256(value.encode()).hexdigest()[:12]


def run_benchmark(args: argparse.Namespace) -> dict[str, Any]:
    validate_arguments(args)
    manifest, fixtures = load_manifest(args.manifest)
    comparing_handy = args.handy_bin is not None
    if comparing_handy:
        missing_languages = [
            fixture["id"]
            for fixture in fixtures
            if not isinstance(fixture.get("language"), str)
            or not fixture["language"].strip()
        ]
        if missing_languages:
            raise ValueError(
                "Handy comparison requires a non-empty fixture language for every input"
            )
    manifest_hash = sha256(args.manifest)
    requested_settings = {
        "vocabulary": args.openramble_vocabulary == "on",
        "prewarm": args.openramble_prewarm == "on",
        "encoder_placement": args.openramble_encoder_placement,
        "vocabulary_scheduling": args.openramble_vocabulary_scheduling,
        "language": args.openramble_language,
        "vocabulary_terms": args.openramble_vocabulary_terms,
    }
    method = {
        "lane": args.lane,
        "warmups_per_fixture_per_engine": args.warmups,
        "measured_pairs_per_fixture": args.repeats,
        "schedule": "balanced deterministic interleaved OH/HO pairs",
        "process_residency": (
            "both engine processes remain alive, loaded, and prewarmed across every pair"
            if comparing_handy
            else "one OpenRamble process remains alive, loaded, and prewarmed across all runs"
        ),
        "seed": args.seed,
        "timer": "engine monotonic integer nanoseconds",
        "language_policy": (
            "the manifest language is applied per request to both engines without "
            "mutating either engine's persisted settings"
            if comparing_handy
            else "the manifest language is applied per OpenRamble request"
        ),
        "quantiles": "Hyndman-Fan type 7 (linear)",
        "metrics": ["minimum", "p50", "p95", "p99", "maximum"],
        "bootstrap": {
            "resamples": args.bootstrap_samples,
            "confidence": 0.95,
            "unit": "paired fixture repetition",
        },
        "public_claim_eligible": False,
        "public_claim_status": "not evaluated; requires manual quality and confidence review",
        "limitations": [
            "Handy uses a locally patched persistent backend harness, not the official app UI path",
            "capture, VAD, overlay, and text insertion are outside both timed boundaries",
            "the engine artifacts may use different formats or quantizations; recorded model fingerprints are authoritative",
            "results apply only to the recorded host, binaries, settings, models, and fixtures",
        ] if comparing_handy else ["no competitor was configured"],
    }

    open_process = JSONLProcess(
        "openramble",
        [str(args.openramble_bin.resolve()), "serve-jsonl"],
        openramble_environment(args),
        args.timeout_seconds,
    )
    handy_process: JSONLProcess | None = None
    if comparing_handy:
        assert args.handy_bin is not None
        assert args.handy_model is not None
        command = [
            str(args.handy_bin.resolve()),
            "--benchmark-jsonl",
            "--model",
            args.handy_model,
            "--no-tray",
        ]
        if args.handy_device_index is not None:
            command.extend(["--device-index", str(args.handy_device_index)])
        handy_process = JSONLProcess(
            "handy",
            command,
            os.environ.copy(),
            args.timeout_seconds,
        )

    try:
        open_load = open_process.request("load")
        open_identity = static_load_identity(open_load)
        validate_openramble_identity(open_identity, requested_settings)
        open_model_fingerprints = reported_model_fingerprints(open_identity)
        open_prewarm = (
            open_process.request("prewarm")
            if args.openramble_prewarm == "on"
            else None
        )

        handy_load: dict[str, Any] | None = None
        handy_prewarm: dict[str, Any] | None = None
        if handy_process is not None:
            handy_load = handy_process.request("load")
            if handy_load.get("source_commit") != args.handy_source_commit:
                raise ValueError("Handy adapter reported a different source commit")
            if handy_load.get("model_id") != args.handy_model:
                raise ValueError("Handy adapter reported a different model id")
            if not isinstance(handy_load.get("effective_settings"), dict):
                raise ValueError("Handy adapter omitted effective settings")
            reported_model_path = handy_load.get("model_path")
            if (
                not isinstance(reported_model_path, str)
                or Path(reported_model_path).resolve()
                != args.handy_model_path.resolve()
            ):
                raise ValueError("Handy adapter loaded a different model path")
            handy_prewarm = handy_process.request("prewarm")

        open_engine = {
            "binary_sha256": sha256(args.openramble_bin),
            "argv": [str(args.openramble_bin.resolve()), "serve-jsonl"],
            "requested_settings": requested_settings,
            "requested_settings_sha256": canonical_json_hash(requested_settings),
            "effective_settings_sha256": canonical_json_hash(
                open_identity["effective_settings"]
            ),
            "reported_identity": open_identity,
            "model_path_fingerprints": open_model_fingerprints,
        }
        engines: dict[str, Any] = {"openramble": open_engine}
        if handy_process is not None:
            assert args.handy_bin is not None
            assert args.handy_model_path is not None
            assert args.handy_patch is not None
            assert args.handy_model_sha256 is not None
            actual_handy_model = path_fingerprint(args.handy_model_path)
            if actual_handy_model["sha256"] != args.handy_model_sha256:
                raise ValueError("Handy model path hash does not match --handy-model-sha256")
            engines["handy"] = {
                "binary_sha256": sha256(args.handy_bin),
                "model_id": args.handy_model,
                "model_path_fingerprint": actual_handy_model,
                "source_commit": args.handy_source_commit,
                "adapter_patch_sha256": sha256(args.handy_patch),
                "reported_identity": static_load_identity(handy_load or {}),
                "effective_settings_sha256": canonical_json_hash(
                    (handy_load or {})["effective_settings"]
                ),
                "provenance": (
                    "locally built Handy backend plus benchmark adapter; not official app parity"
                ),
            }

        identity_payload = {
            "schema_version": SCHEMA_VERSION,
            "manifest_sha256": manifest_hash,
            "host": host_identity(),
            "method": method,
            "engines": engines,
        }
        experiment_hash = canonical_json_hash(identity_payload)
        fresh_report: dict[str, Any] = {
            **identity_payload,
            "experiment_identity_sha256": experiment_hash,
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "sources": manifest.get("sources", {}),
            "sessions": [],
            "fixtures": [],
        }

        if args.resume and args.output.exists():
            report = json.loads(args.output.read_text(encoding="utf-8"))
            if report.get("experiment_identity_sha256") != experiment_hash:
                raise ValueError("resume refused: experiment identity changed")
        else:
            if args.output.exists() and args.resume:
                raise ValueError("--resume output does not exist")
            report = fresh_report

        session: dict[str, Any] = {
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "openramble_load_ns": open_load.get("load_ns"),
            "openramble_prewarm_ns": (open_prewarm or {}).get("prewarm_ns"),
            "handy_load_ns": (handy_load or {}).get("load_ns"),
            "handy_prewarm_ns": (handy_prewarm or {}).get("prewarm_ns"),
        }
        report.setdefault("sessions", []).append(session)
        write_report(args.output, report)

        with tempfile.TemporaryDirectory(prefix="openramble-paired-benchmark-") as temp:
            canonical_root = Path(temp)
            for fixture in fixtures:
                fixture_id = fixture["id"]
                canonical_path = canonical_root / (safe_filename(fixture_id) + ".f32le")
                open_preload = open_process.request(
                    "preload",
                    key=fixture_id,
                    path=fixture["path"],
                    format="audio",
                    canonical_path=str(canonical_path),
                )
                canonical_hash = open_preload.get("pcm_f32le_sha256")
                validate_hex(canonical_hash, HEX_64, f"{fixture_id} canonical PCM SHA-256")
                if not canonical_path.is_file() or sha256(canonical_path) != canonical_hash:
                    raise RuntimeError(f"{fixture_id}: exported canonical PCM hash mismatch")
                if handy_process is not None:
                    handy_preload = handy_process.request(
                        "preload",
                        key=fixture_id,
                        path=str(canonical_path),
                        format="f32le",
                    )
                    if handy_preload.get("pcm_f32le_sha256") != canonical_hash:
                        raise RuntimeError(f"{fixture_id}: engines did not preload identical PCM")

                warmup_schedule = (
                    balanced_schedule(args.warmups, args.seed, fixture_id, "warmup")
                    if handy_process is not None
                    else ["O"] * args.warmups
                )
                measured_schedule = (
                    balanced_schedule(args.repeats, args.seed, fixture_id, "measured")
                    if handy_process is not None
                    else ["O"] * args.repeats
                )
                existing = next(
                    (item for item in report["fixtures"] if item.get("id") == fixture_id),
                    None,
                )
                fixture_static = {
                    key: value
                    for key, value in fixture.items()
                    if key not in {"path", "reference"}
                }
                fixture_static.update(
                    {
                        "id": fixture_id,
                        "source_file_sha256": fixture["sha256"],
                        "reference_sha256": hashlib.sha256(
                            fixture.get("reference", "").encode("utf-8")
                        ).hexdigest()
                        if fixture.get("reference") is not None
                        else None,
                        "canonical_pcm": {
                            "format": "f32le",
                            "sample_rate": open_preload.get("sample_rate"),
                            "sample_count": open_preload.get("sample_count"),
                            "audio_duration_ns": open_preload.get("audio_duration_ns"),
                            "sha256": canonical_hash,
                        },
                        "warmup_schedule": warmup_schedule,
                        "measured_schedule": measured_schedule,
                    }
                )
                if existing is None:
                    item = {**fixture_static, "warmup_observations": [], "pairs": []}
                    report["fixtures"].append(item)
                else:
                    item = existing
                    for key, value in fixture_static.items():
                        if item.get(key) != value:
                            raise ValueError(f"{fixture_id}: resume fixture identity changed at {key}")
                    # A checkpoint is written only after both members of a pair.
                    # Reject rather than silently treating an unpaired sample as paired.
                    if any(
                        "openramble" not in pair
                        or (handy_process is not None and "handy" not in pair)
                        for pair in item.get("pairs", [])
                    ):
                        raise ValueError(f"{fixture_id}: checkpoint contains an incomplete pair")
                    checkpoint_indices = [pair.get("index") for pair in item.get("pairs", [])]
                    if (
                        any(not isinstance(index, int) for index in checkpoint_indices)
                        or len(set(checkpoint_indices)) != len(checkpoint_indices)
                        or any(index < 0 or index >= args.repeats for index in checkpoint_indices)
                    ):
                        raise ValueError(f"{fixture_id}: checkpoint pair indices are invalid")

                expected_hash = canonical_hash if args.lane == "predecoded-product-warm" else None
                # Every new process/session is warmed independently, including on resume.
                current_warmups: list[dict[str, Any]] = []
                for warmup_index, order in enumerate(warmup_schedule):
                    observation: dict[str, Any] = {"index": warmup_index, "order": order}
                    order_engines = ("openramble",) if order == "O" else ENGINE_ORDER[order]
                    for engine_name in order_engines:
                        process = open_process if engine_name == "openramble" else handy_process
                        assert process is not None
                        observation[engine_name] = execute_observation(
                            process, engine_name, args.lane, fixture, expected_hash
                        )
                    current_warmups.append(observation)
                item["warmup_observations"] = current_warmups
                write_report(args.output, report)

                completed = {pair["index"] for pair in item["pairs"]}
                for pair_index, order in enumerate(measured_schedule):
                    if pair_index in completed:
                        continue
                    pair: dict[str, Any] = {"index": pair_index, "order": order}
                    order_engines = ("openramble",) if order == "O" else ENGINE_ORDER[order]
                    for engine_name in order_engines:
                        process = open_process if engine_name == "openramble" else handy_process
                        assert process is not None
                        pair[engine_name] = execute_observation(
                            process, engine_name, args.lane, fixture, expected_hash
                        )
                    item["pairs"].append(pair)
                    item["pairs"].sort(key=lambda value: value["index"])
                    write_report(args.output, report)
                    print(
                        f"{fixture_id}: completed pair {pair_index + 1}/{args.repeats} ({order})",
                        flush=True,
                    )

                if len(item["pairs"]) != args.repeats:
                    raise RuntimeError(f"{fixture_id}: measured pair count is incomplete")
                item["summary"] = fixture_summary(
                    item, args.bootstrap_samples, args.seed
                )
                write_report(args.output, report)

        session["completed_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        write_report(args.output, report)
        return report
    finally:
        if handy_process is not None:
            handy_process.close()
        open_process.close()


def main(argv: list[str] | None = None) -> None:
    args = arguments(argv)
    run_benchmark(args)
    print(f"Report: {args.output}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, TimeoutError, ValueError, json.JSONDecodeError) as error:
        print(f"benchmark failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
