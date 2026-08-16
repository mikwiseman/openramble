#!/usr/bin/env python3
"""Run the endpoint fixture matrix through one warm shipping product process."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import statistics
import subprocess
import threading
import time


def sha256_json(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    ).hexdigest()


class ProductProcess:
    def __init__(self, binary: pathlib.Path, stderr_path: pathlib.Path) -> None:
        environment = os.environ.copy()
        environment.update(
            {
                "OPENRAMBLE_TEMP_MODEL_WINDOW_SECONDS": "15",
                "WAI_VOCAB": "on",
                "WAI_ASR_VOCAB_SCHEDULING": "candidateRegions",
                "WAI_ASR_CHUNK_CONCURRENCY": "4",
                "WAI_ASR_MAX_TOKENS": "600",
            }
        )
        self.stderr_handle = stderr_path.open("w", encoding="utf-8")
        self.process = subprocess.Popen(
            [str(binary), "serve-jsonl"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
            env=environment,
        )
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        assert self.process.stderr is not None

        def drain_stderr() -> None:
            assert self.process.stderr is not None
            for line in self.process.stderr:
                self.stderr_handle.write(line)
                self.stderr_handle.flush()

        self.stderr_thread = threading.Thread(target=drain_stderr, daemon=True)
        self.stderr_thread.start()
        self.next_id = 1

    def request(self, command: dict[str, object]) -> dict[str, object]:
        request = {"id": self.next_id, **command}
        self.next_id += 1
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(f"product process exited with {self.process.poll()}")
        response = json.loads(line)
        if response.get("id") != request["id"] or not response.get("ok"):
            raise RuntimeError(f"product request failed: {response}")
        return response

    def close(self) -> None:
        try:
            if self.process.poll() is None:
                self.request({"command": "shutdown"})
        finally:
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=10)
            self.stderr_thread.join(timeout=2)
            self.stderr_handle.close()


def scrub(response: dict[str, object]) -> dict[str, object]:
    """Persist hashes/times only, never dictated text or individual tokens."""

    timing = response.get("timing")
    tokens = response.get("tokens", [])
    words = response.get("words", [])
    return {
        "elapsed_ns": response["elapsed_ns"],
        "audio_duration_ns": response["audio_duration_ns"],
        "processing_duration_ns": response["processing_duration_ns"],
        "sample_count": response["sample_count"],
        "pcm_f32le_sha256": response["pcm_f32le_sha256"],
        "raw_transcript_sha256": response["raw_transcript_sha256"],
        "normalized_transcript_sha256": response["normalized_transcript_sha256"],
        "token_timing_sha256": response["token_timing_sha256"],
        "word_timing_sha256": response["word_timing_sha256"],
        "token_count": len(tokens) if isinstance(tokens, list) else None,
        "word_count": len(words) if isinstance(words, list) else None,
        "peak_rss_bytes": response["peak_rss_bytes"],
        "timing": timing,
    }


def semantic_fingerprint(result: dict[str, object]) -> str:
    timing = result.get("timing")
    outcome = timing.get("vocabulary_outcome") if isinstance(timing, dict) else None
    return sha256_json(
        {
            "raw_transcript": result["raw_transcript_sha256"],
            "normalized_transcript": result["normalized_transcript_sha256"],
            "tokens": result["token_timing_sha256"],
            "words": result["word_timing_sha256"],
            "vocabulary_outcome": outcome,
        }
    )


def median_elapsed(runs: list[dict[str, object]]) -> int:
    return round(statistics.median(int(run["elapsed_ns"]) for run in runs))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepared", type=pathlib.Path, required=True)
    parser.add_argument("--binary", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--repeats", type=int, default=2)
    args = parser.parse_args()

    prepared = json.loads(args.prepared.read_text(encoding="utf-8"))
    output_dir = args.output.parent
    output_dir.mkdir(parents=True, exist_ok=True)

    fixture_language: dict[str, str] = {}
    paths: dict[str, pathlib.Path] = {}
    path_fixture: dict[str, str] = {}
    references: dict[str, dict[str, str]] = {}
    for fixture in prepared["fixtures"]:
        fixture_id = fixture["fixture"]["fixture_id"]
        fixture_language[fixture_id] = fixture["fixture"]["language"]
        references[fixture_id] = {}
        candidate_paths = {"base": fixture["base_path"]}
        for variant in fixture["variants"]:
            candidate_paths[f"{variant['label']}:raw"] = variant["raw_path"]
            candidate_paths[f"{variant['label']}:canonical"] = variant["canonical_path"]
            if variant.get("snapshot_path"):
                candidate_paths[f"{variant['label']}:snapshot"] = variant["snapshot_path"]
        for reference, raw_path in candidate_paths.items():
            path = pathlib.Path(raw_path)
            data_hash = hashlib.sha256(path.read_bytes()).hexdigest()
            key = f"{fixture_id}:{data_hash}"
            paths[key] = path
            path_fixture[key] = fixture_id
            references[fixture_id][reference] = key

    started = time.monotonic_ns()
    server = ProductProcess(args.binary.resolve(), output_dir / "product-matrix.stderr.log")
    runs: dict[str, list[dict[str, object]]] = {}
    process_metadata: dict[str, object] = {}
    try:
        load = server.request({"command": "load"})
        process_metadata = {
            "load_ns": load["load_ns"],
            "effective_settings": load["effective_settings"],
            "model": load["model"],
            "vocabulary_model": load["vocabulary_model"],
        }
        prewarm = server.request({"command": "prewarm"})
        process_metadata["prewarm_ns"] = prewarm["prewarm_ns"]

        for key, path in sorted(paths.items()):
            response = server.request(
                {"command": "preload", "key": key, "path": str(path), "format": "f32le"}
            )
            expected_hash = key.rsplit(":", 1)[1]
            if response["pcm_f32le_sha256"] != expected_hash:
                raise RuntimeError(f"preload hash mismatch for {path}")

        for key in sorted(paths):
            runs[key] = []
            for _ in range(args.repeats):
                response = server.request(
                    {
                        "command": "run",
                        "key": key,
                        "language": fixture_language[path_fixture[key]],
                    }
                )
                runs[key].append(scrub(response))
    finally:
        server.close()

    analysis: dict[str, object] = {
        "fixtures": [],
        "all_repeats_deterministic": True,
    }
    for fixture in prepared["fixtures"]:
        fixture_id = fixture["fixture"]["fixture_id"]
        refs = references[fixture_id]
        base_runs = runs[refs["base"]]
        base_fingerprint = semantic_fingerprint(base_runs[0])
        fixture_analysis: dict[str, object] = {
            "fixture_id": fixture_id,
            "vocabulary": fixture["fixture"]["vocabulary"],
            "variants": [],
        }
        for variant in fixture["variants"]:
            raw_runs = runs[refs[f"{variant['label']}:raw"]]
            canonical_runs = runs[refs[f"{variant['label']}:canonical"]]
            raw_deterministic = len({semantic_fingerprint(run) for run in raw_runs}) == 1
            canonical_deterministic = (
                len({semantic_fingerprint(run) for run in canonical_runs}) == 1
            )
            analysis["all_repeats_deterministic"] = bool(
                analysis["all_repeats_deterministic"]
                and raw_deterministic
                and canonical_deterministic
            )
            raw_fingerprint = semantic_fingerprint(raw_runs[0])
            canonical_fingerprint = semantic_fingerprint(canonical_runs[0])
            raw_elapsed = median_elapsed(raw_runs)
            canonical_elapsed = median_elapsed(canonical_runs)
            headstart_ns = max(
                0,
                round(
                    (
                        variant["observed_trailing_silence_samples"] / 16_000
                        - prepared["canonicalizer"]["settle_seconds"]
                    )
                    * 1_000_000_000
                ),
            )
            match_wait_ns = max(0, canonical_elapsed - headstart_ns)
            mismatch_extra_wait_ns = max(0, canonical_elapsed - headstart_ns)
            raw_outcome = raw_runs[0]["timing"]["vocabulary_outcome"]
            canonical_outcome = canonical_runs[0]["timing"]["vocabulary_outcome"]
            fixture_analysis["variants"].append(
                {
                    "kind": variant["kind"],
                    "seconds": variant["seconds"],
                    "label": variant["label"],
                    "raw_sample_count": variant["raw_sample_count"],
                    "canonical_sample_count": variant["canonical_sample_count"],
                    "endpoint_eligible": variant["endpoint_eligible"],
                    "digest_matches": variant.get("digest_matches"),
                    "raw_repeats_deterministic": raw_deterministic,
                    "canonical_repeats_deterministic": canonical_deterministic,
                    "raw_matches_base_semantics": raw_fingerprint == base_fingerprint,
                    "canonical_matches_raw_semantics": canonical_fingerprint
                    == raw_fingerprint,
                    "raw_audio_duration_matches_canonical": raw_runs[0]["audio_duration_ns"]
                    == canonical_runs[0]["audio_duration_ns"],
                    "raw_vocabulary_outcome": raw_outcome,
                    "canonical_vocabulary_outcome": canonical_outcome,
                    "raw_median_elapsed_ns": raw_elapsed,
                    "canonical_median_elapsed_ns": canonical_elapsed,
                    "speculation_headstart_ns": headstart_ns,
                    "matched_cache_stop_wait_ns": match_wait_ns,
                    "matched_cache_inference_overlap_saved_ns": canonical_elapsed
                    - match_wait_ns,
                    "mismatch_extra_stop_wait_before_normal_fallback_ns": mismatch_extra_wait_ns,
                    "normal_fallback_ns": raw_elapsed,
                    "mismatch_total_stop_inference_ns": mismatch_extra_wait_ns + raw_elapsed,
                }
            )
        analysis["fixtures"].append(fixture_analysis)

    report = {
        "schema_version": 1,
        "prepared_fixture_report": str(args.prepared.resolve()),
        "binary": str(args.binary.resolve()),
        "repeats": args.repeats,
        "persistent_process": True,
        "wall_ns": time.monotonic_ns() - started,
        "process": process_metadata,
        "references": references,
        "runs": runs,
        "analysis": analysis,
    }
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(args.output)


if __name__ == "__main__":
    main()
