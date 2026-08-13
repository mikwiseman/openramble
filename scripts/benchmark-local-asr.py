#!/usr/bin/env python3
"""Reproducible warm/cold local-ASR comparison for OpenRamble and Handy."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import statistics
import subprocess
from pathlib import Path
from typing import Any


OPENRAMBLE_BLOCK = re.compile(
    r"=== .*? ===\n(?P<text>.*?)\n---\n"
    r"audio: (?P<audio>[0-9.]+) s\n"
    r"recognized: (?P<wall>[0-9.]+) s\n"
    r"(?P<rtf>[0-9.]+) times faster than real time\n"
    r"words with timings: [0-9]+\n"
    r"peak memory: (?P<memory>[0-9.]+) MB",
    re.DOTALL,
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument(
        "--openramble-bin",
        type=Path,
        default=Path("Packages/LocalASR/.build/release/asr-bench"),
    )
    parser.add_argument("--handy-bin", type=Path)
    parser.add_argument("--handy-model")
    parser.add_argument("--repeats", type=int, default=9)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--timeout-seconds", type=float, default=1800)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--resume", action="store_true")
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = fraction * (len(ordered) - 1)
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def summarize(values: list[float], audio_seconds: float) -> dict[str, Any]:
    return {
        "runs_seconds": values,
        "minimum_seconds": min(values),
        "median_seconds": statistics.median(values),
        "p95_seconds": percentile(values, 0.95),
        "median_realtime_factor": audio_seconds / statistics.median(values),
    }


def words(text: str) -> list[str]:
    return re.findall(r"[\w']+", text.casefold(), flags=re.UNICODE)


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


def run(
    command: list[str],
    environment: dict[str, str] | None = None,
    timeout_seconds: float = 1800,
) -> str:
    completed = subprocess.run(
        command,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        timeout=timeout_seconds,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip().splitlines()[-1:] or ["no stderr"]
        raise RuntimeError(
            f"command exited {completed.returncode}: {Path(command[0]).name}: {detail[0]}"
        )
    return completed.stdout


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def benchmark_openramble(
    executable: Path,
    fixture: dict[str, Any],
    repeats: int,
    warmups: int,
    timeout_seconds: float,
) -> dict[str, Any]:
    path = str(Path(fixture["path"]).resolve())
    total = repeats + warmups
    environment = os.environ.copy()
    environment.update({"WAI_VOCAB": "on", "WAI_ASR_PREWARM": "on"})
    output = run(
        [str(executable), "bench", *([path] * total)],
        environment,
        timeout_seconds,
    )
    matches = list(OPENRAMBLE_BLOCK.finditer(output))
    if len(matches) != total:
        raise RuntimeError(f"expected {total} OpenRamble samples, found {len(matches)}")
    measured = matches[warmups:]
    values = [float(match.group("wall")) for match in measured]
    audio = float(measured[-1].group("audio"))
    load = re.search(r"Model loaded in ([0-9.]+) s", output)
    vocabulary = re.search(r"Prompt loaded in ([0-9.]+)", output)
    prewarm = re.search(r"Inference warmed in ([0-9.]+) s", output)
    transcript = measured[-1].group("text").strip()
    return {
        **summarize(values, audio),
        "audio_seconds": audio,
        "model_load_seconds": float(load.group(1)) if load else None,
        "vocabulary_load_seconds": float(vocabulary.group(1)) if vocabulary else None,
        "prewarm_seconds": float(prewarm.group(1)) if prewarm else None,
        "first_fixture_run_seconds": float(matches[0].group("wall")),
        "peak_rss_mb": max(float(match.group("memory")) for match in matches),
        "transcript_sha256": hashlib.sha256(transcript.encode()).hexdigest(),
        "word_error_rate": word_error_rate(fixture.get("reference"), transcript),
    }


def last_json_object(output: str) -> dict[str, Any]:
    for line in reversed(output.splitlines()):
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    raise RuntimeError("Handy did not emit a JSON result")


def benchmark_handy(
    executable: Path,
    model: str,
    fixture: dict[str, Any],
    repeats: int,
    warmups: int,
    timeout_seconds: float,
) -> dict[str, Any]:
    total = repeats + warmups
    output = run(
        [
            str(executable),
            "--transcribe-file",
            str(Path(fixture["path"]).resolve()),
            "--model",
            model,
            "--repeat",
            str(total),
            "--json",
            "--no-tray",
        ],
        timeout_seconds=timeout_seconds,
    )
    result = last_json_object(output)
    milliseconds = [float(value) for value in result["transcribe_ms"]]
    if len(milliseconds) != total:
        raise RuntimeError(
            f"expected {total} Handy samples, found {len(milliseconds)}"
        )
    values = [value / 1000 for value in milliseconds[warmups:]]
    transcript = str(result["text"]).strip()
    audio = float(result["audio_secs"])
    return {
        **summarize(values, audio),
        "audio_seconds": audio,
        "model_load_seconds": float(result["load_ms"]) / 1000,
        "first_fixture_run_seconds": milliseconds[0] / 1000,
        "bound_backend": result.get("bound_backend"),
        "transcript_sha256": hashlib.sha256(transcript.encode()).hexdigest(),
        "word_error_rate": word_error_rate(fixture.get("reference"), transcript),
    }


def main() -> None:
    args = arguments()
    if args.repeats < 3 or args.warmups < 1:
        raise SystemExit("use at least 3 measured repeats and 1 warm-up")
    manifest = json.loads(args.manifest.read_text())
    fixtures = manifest["fixtures"]
    method = {
        "warmups": args.warmups,
        "measured_repeats": args.repeats,
        "statistic": "median and linearly interpolated p95",
        "openramble_vocabulary": True,
        "openramble_prewarm": True,
    }

    def sysctl(name: str) -> str | None:
        try:
            return subprocess.check_output(["sysctl", "-n", name], text=True).strip()
        except (OSError, subprocess.CalledProcessError):
            return None

    fresh_report: dict[str, Any] = {
        "schema_version": 1,
        "manifest_sha256": sha256(args.manifest),
        "generated_at": subprocess.check_output(
            ["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], text=True
        ).strip(),
        "host": {
            "machine": platform.machine(),
            "macos": platform.mac_ver()[0],
            "chip": sysctl("machdep.cpu.brand_string"),
            "memory_bytes": int(sysctl("hw.memsize") or 0) or None,
        },
        "method": method,
        "sources": manifest.get("sources", {}),
        "fixtures": [],
    }
    report = json.loads(args.output.read_text()) if args.resume and args.output.exists() else fresh_report
    if report.get("manifest_sha256") != fresh_report["manifest_sha256"]:
        raise SystemExit("resume report was created from a different manifest")
    if report.get("method") != method:
        raise SystemExit("resume report uses different warm-up or repeat settings")
    write_report(args.output, report)
    for fixture in fixtures:
        existing = next(
            (item for item in report["fixtures"] if item.get("id") == fixture["id"]),
            None,
        )
        if existing and "openramble" in existing and (
            not (args.handy_bin and args.handy_model) or "handy" in existing
        ):
            print(f"{fixture['id']}: resumed from checkpoint", flush=True)
            continue
        path = Path(fixture["path"]).resolve()
        item = existing or {
            **{
                key: value
                for key, value in fixture.items()
                if key not in {"path", "reference"}
            },
            "sha256": sha256(path),
            "reference_sha256": hashlib.sha256(
                fixture.get("reference", "").encode()
            ).hexdigest()
            if fixture.get("reference") is not None
            else None,
        }
        if existing is None:
            report["fixtures"].append(item)
        if "openramble" not in item:
            item["openramble"] = benchmark_openramble(
                args.openramble_bin,
                fixture,
                args.repeats,
                args.warmups,
                args.timeout_seconds,
            )
            write_report(args.output, report)
        if args.handy_bin and args.handy_model:
            if "handy" not in item:
                item["handy"] = benchmark_handy(
                    args.handy_bin,
                    args.handy_model,
                    fixture,
                    args.repeats,
                    args.warmups,
                    args.timeout_seconds,
                )
            item["openramble_vs_handy_median_ratio"] = (
                item["handy"]["median_seconds"]
                / item["openramble"]["median_seconds"]
            )
            write_report(args.output, report)
        print(
            f"{item['id']}: OpenRamble {item['openramble']['median_seconds']:.4f}s",
            flush=True,
        )

    write_report(args.output, report)
    print(f"Report: {args.output}")


if __name__ == "__main__":
    main()
