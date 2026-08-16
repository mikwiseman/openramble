#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
import random
import statistics
import subprocess
import time
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def quantile(values: list[int], probability: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * probability
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return float(ordered[lower])
    fraction = position - lower
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction


def summarize(values: list[int]) -> dict:
    return {
        "count": len(values),
        "minimum_ns": min(values),
        "p50_ns": quantile(values, 0.50),
        "p95_ns": quantile(values, 0.95),
        "p99_ns": quantile(values, 0.99),
        "maximum_ns": max(values),
        "mean_ns": statistics.fmean(values),
    }


class Server:
    def __init__(self, label: str, executable: Path, environment: dict[str, str]):
        self.label = label
        self.executable = executable
        self.request_id = 0
        self.stderr_path = Path(f"$TMP/openramble-two-or-{label}.stderr.log")
        self.stderr = self.stderr_path.open("w", encoding="utf-8")
        self.process = subprocess.Popen(
            [str(executable), "serve-jsonl"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr,
            text=True,
            bufsize=1,
            env=environment,
        )

    def request(self, command: str, **payload):
        self.request_id += 1
        request = {"id": self.request_id, "command": command, **payload}
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(
                f"{self.label} exited while handling {command}; stderr={self.stderr_path}"
            )
        response = json.loads(line)
        if response.get("id") != self.request_id or not response.get("ok"):
            raise RuntimeError(f"{self.label} invalid response: {response}")
        return response

    def close(self):
        if self.process.poll() is None:
            try:
                self.request("shutdown")
            except Exception:
                self.process.terminate()
        self.process.wait(timeout=10)
        self.stderr.close()


def sanitized_run(response: dict) -> dict:
    return {
        key: value
        for key, value in response.items()
        if key not in {"id", "text"}
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--language", default="ru")
    parser.add_argument("--warmups", type=int, default=6)
    parser.add_argument("--repeats", type=int, default=80)
    parser.add_argument("--seed", type=int, default=20260814)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if args.repeats <= 0 or args.repeats % 2:
        raise ValueError("--repeats must be a positive even number")
    environment = os.environ.copy()
    environment.update(
        {
            "WAI_VOCAB": "on",
            "WAI_ASR_ENCODER_PLACEMENT": "automatic",
            "WAI_ASR_CHUNK_CONCURRENCY": "4",
            "WAI_ASR_VOCAB_SCHEDULING": "candidateRegions",
        }
    )

    servers = {
        "baseline": Server("baseline", args.baseline.resolve(), environment),
        "candidate": Server("candidate", args.candidate.resolve(), environment),
    }
    try:
        load = {name: server.request("load") for name, server in servers.items()}
        settings = [value["effective_settings"] for value in load.values()]
        if settings[0] != settings[1]:
            raise RuntimeError(f"effective settings differ: {settings}")
        prewarm = {name: server.request("prewarm") for name, server in servers.items()}
        preload = {
            name: server.request(
                "preload", key="fixture", path=str(args.fixture.resolve()), format="audio"
            )
            for name, server in servers.items()
        }
        if len({value["pcm_f32le_sha256"] for value in preload.values()}) != 1:
            raise RuntimeError("canonical PCM differs")

        warmup_schedule = ["baseline", "candidate"] * (args.warmups // 2)
        if args.warmups % 2:
            warmup_schedule.append("baseline")
        warmups = []
        for first in warmup_schedule:
            second = "candidate" if first == "baseline" else "baseline"
            pair = {}
            for name in (first, second):
                response = servers[name].request("run", key="fixture", language=args.language)
                pair[name] = sanitized_run(response)
            warmups.append({"order": first[0].upper() + second[0].upper(), **pair})

        schedule = ["baseline"] * (args.repeats // 2) + ["candidate"] * (args.repeats // 2)
        random.Random(args.seed).shuffle(schedule)
        pairs = []
        for pair_index, first in enumerate(schedule):
            second = "candidate" if first == "baseline" else "baseline"
            pair = {}
            texts = {}
            for name in (first, second):
                response = servers[name].request("run", key="fixture", language=args.language)
                texts[name] = response["text"]
                pair[name] = sanitized_run(response)
            if texts["baseline"] != texts["candidate"]:
                raise RuntimeError(f"transcript mismatch at pair {pair_index}")
            pairs.append({"index": pair_index, "order": first[0].upper() + second[0].upper(), **pair})
            print(f"pair {pair_index + 1}/{args.repeats} {pairs[-1]['order']}", flush=True)

        summaries = {}
        for name in servers:
            elapsed = [pair[name]["elapsed_ns"] for pair in pairs]
            phases = {}
            for key in (
                "primary_tdt_inference_decode_ns",
                "lexical_candidate_gate_ns",
                "ctc_model_inference_ns",
                "ctc_rescoring_fusion_ns",
            ):
                samples = [
                    pair[name]["timing"]["phases"][key]
                    for pair in pairs
                    if pair[name]["timing"]["phases"][key] is not None
                ]
                phases[key] = summarize(samples) if samples else None
            summaries[name] = {"elapsed": summarize(elapsed), "phases": phases}

        baseline_p50 = summaries["baseline"]["elapsed"]["p50_ns"]
        candidate_p50 = summaries["candidate"]["elapsed"]["p50_ns"]
        report = {
            "schema_version": 1,
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "method": {
                "lane": "predecoded-product-warm",
                "schedule": "balanced persistent-process BC/CB pairs",
                "warmups": args.warmups,
                "repeats": args.repeats,
                "seed": args.seed,
                "public_claim_eligible": False,
            },
            "binaries": {
                name: {"path": str(server.executable), "sha256": sha256(server.executable)}
                for name, server in servers.items()
            },
            "fixture": {
                "path": str(args.fixture.resolve()),
                "sha256": sha256(args.fixture),
                "language": args.language,
                "pcm_f32le_sha256": preload["baseline"]["pcm_f32le_sha256"],
                "sample_count": preload["baseline"]["sample_count"],
            },
            "effective_settings": settings[0],
            "load": {name: sanitized_run(value) for name, value in load.items()},
            "prewarm": {name: sanitized_run(value) for name, value in prewarm.items()},
            "warmup_observations": warmups,
            "pairs": pairs,
            "summary": summaries,
            "candidate_p50_delta_percent": (candidate_p50 / baseline_p50 - 1.0) * 100.0,
        }
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(json.dumps(report["summary"], indent=2, sort_keys=True))
        print(f"candidate p50 delta: {report['candidate_p50_delta_percent']:.2f}%")
        return 0
    finally:
        for server in servers.values():
            server.close()


if __name__ == "__main__":
    raise SystemExit(main())
