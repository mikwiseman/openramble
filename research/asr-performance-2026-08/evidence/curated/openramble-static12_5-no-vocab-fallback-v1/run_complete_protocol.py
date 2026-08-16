#!/usr/bin/env python3
"""Counterfactual fail-closed 204-row A/B runner. It never scores quality."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import subprocess
import threading
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path("$TMP/openramble-static12_5-no-vocab-fallback-v1")
MANIFEST = Path(
    "$TMP/openramble-dominant-short-quality-v1/final-corpus/manifest.json"
)
PREREGISTRATION = ROOT / "PREREGISTRATION.json"
LINEAGE = Path("$TMP/openramble-intermediate-quality-gate/ARTIFACT_LINEAGE.json")
CONFIG = Path("$TMP/openramble-intermediate-quality-gate/PRODUCT_CONFIG.json")
BINARY = Path(
    "$TMP/openramble-short-quality-gate/src/Packages/LocalASR/"
    ".build/release/asr-bench"
)
SHIPPING = Path(
    "$HOME/Library/Application Support/OpenRamble/Models/"
    "parakeet-tdt-0.6b-v3/aed02740059203c4a87495924f685de3722ae9ce/"
    "parakeet-tdt-0.6b-v3"
)
VOCAB = Path(
    "$HOME/Library/Application Support/OpenRamble/Models/"
    "parakeet-ctc-110m/accdafd8cf8a2ff1cabe3c11e54416b405d409aa/"
    "parakeet-ctc-110m"
)
KNOWN_OUTCOMES = {
    "no_candidate",
    "unmodified",
    "candidate_no_usable_evidence",
    "rescored_unmodified",
    "rescored_modified",
}
CANDIDATE_OUTCOMES = {
    "candidate_no_usable_evidence",
    "rescored_unmodified",
    "rescored_modified",
}
VARIANTS = {
    "shipping": {
        "role": "shipping",
        "shape": 15.0,
        "cohort": None,
        "model": SHIPPING,
        "lineage_key": None,
    },
    "candidate-12.5": {
        "role": "candidate",
        "shape": 12.5,
        "cohort": None,
        "model": Path(
            "$TMP/openramble-intermediate-quality-gate/models/"
            "static-12.5s/parakeet-tdt-0.6b-v3"
        ),
        "lineage_key": "12.5",
    },
}
SMOKE = [
    {
        "id": "real-en-librispeech-test-other",
        "path": "$REPO/.gstack/benchmark-fixtures/librispeech-test-other-1688-142285-0007-pcm16.wav",
        "source_sha256": "0ef932371d181b185f01b2ede213ebe649650457e5781d8e428f831dfbbe5343",
        "language": "en",
    },
    {
        "id": "real-en-voices-room",
        "path": "$REPO/.gstack/benchmark-fixtures/voices-room-sp0307.wav",
        "source_sha256": "c65fcd726d6b08c82c1e5dc7558f863cd8d483e3ed2f4a7bcf271dc1865ada14",
        "language": "en",
    },
    {
        "id": "real-ru-fleurs-validation-1",
        "path": "/tmp/openramble-fleurs-ru-validation-1.wav",
        "source_sha256": "363087f90513f5484750d8076da3cf7d029065d6b09f7ea68170bcf10b487d27",
        "language": "ru",
    },
    {
        "id": "real-ru-fleurs-validation-6",
        "path": "/tmp/openramble-fleurs-ru-validation-6.wav",
        "source_sha256": "de6c6c691caf96369381f26aa204c4455d8f7c625dec017b634f9ff25833211f",
        "language": "ru",
    },
]


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_sha(path: Path) -> str:
    files = []
    for item in sorted(path.rglob("*")):
        if item.is_file():
            files.append(
                {
                    "path": item.relative_to(path).as_posix(),
                    "bytes": item.stat().st_size,
                    "sha256": sha(item),
                }
            )
    encoded = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


def atomic_json(path: Path, value: dict, mode: int = 0o644) -> None:
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    os.replace(temp, path)
    os.chmod(path, mode)


def validate_result(item: dict, duration: float) -> list[str]:
    failures = []
    if item.get("ok") is not True or item.get("protocol_version") != 1:
        failures.append("invalid protocol success envelope")
    if item.get("prewarmed") is not True:
        failures.append("result was not prewarmed")
    if not isinstance(item.get("text"), str):
        failures.append("transcript is not a string")
    if item.get("sample_rate") != 16000 or not isinstance(item.get("sample_count"), int):
        failures.append("invalid sample contract")
    timing = item.get("timing")
    if not isinstance(timing, dict):
        failures.append("timing is not an object")
    else:
        outcome = timing.get("vocabulary_outcome")
        invocations = timing.get("ctc_inference_invocations")
        if outcome not in KNOWN_OUTCOMES:
            failures.append(f"unknown vocabulary outcome {outcome!r}")
        elif outcome in CANDIDATE_OUTCOMES and invocations != 1:
            failures.append("candidate outcome without exactly one CTC invocation")
        elif outcome not in CANDIDATE_OUTCOMES and invocations not in (0, None):
            failures.append("non-candidate outcome with CTC invocation")
    for label in ("tokens", "words"):
        values = item.get(label)
        if not isinstance(values, list):
            failures.append(f"{label} is not an array")
            continue
        previous_start = -math.inf
        previous_end = -math.inf
        for index, value in enumerate(values):
            if not isinstance(value, dict) or not isinstance(value.get("text"), str) or not value["text"]:
                failures.append(f"{label}[{index}] invalid text")
                continue
            try:
                start = float(value["start"])
                end = float(value["end"])
                confidence = float(value["confidence"])
            except (KeyError, TypeError, ValueError):
                failures.append(f"{label}[{index}] missing numeric fields")
                continue
            if not all(math.isfinite(x) for x in (start, end, confidence)):
                failures.append(f"{label}[{index}] non-finite fields")
            if start < -1e-9 or end + 1e-9 < start or end > duration + 0.0800001:
                failures.append(f"{label}[{index}] invalid span")
            if start + 1e-9 < previous_start or end + 1e-9 < previous_end:
                failures.append(f"{label}[{index}] non-monotonic span")
            if not 0.0 <= confidence <= 1.0:
                failures.append(f"{label}[{index}] invalid confidence")
            if label == "tokens" and not isinstance(value.get("id"), int):
                failures.append(f"{label}[{index}] invalid token id")
            previous_start, previous_end = start, end
    return failures


class Engine:
    def __init__(self, variant: str, config: dict, stderr_path: Path, wire_path: Path):
        self.variant = variant
        self.config = config
        self.next_id = 1
        environment = os.environ.copy()
        environment.update(
            {
                "WAI_ASR_MODEL_DIR": str(config["model"]),
                "WAI_VOCAB": "on",
                "WAI_VOCAB_DIR": str(VOCAB),
                "WAI_VOCAB_TERMS": "28",
                "WAI_VOCAB_SIMILARITY": "0.65",
                "WAI_VOCAB_CBW": "3.0",
                "WAI_ASR_ENCODER": "palettized6bit",
                "WAI_ASR_ENCODER_PLACEMENT": "automatic",
                "WAI_ASR_MEL_CONTEXT": "off",
                "WAI_ASR_DUAL_DECODE": "off",
                "WAI_ASR_MAX_TOKENS": "600",
                "WAI_ASR_CHUNK_CONCURRENCY": "4",
                "WAI_ASR_VOCAB_SCHEDULING": "candidateRegions",
            }
        )
        if config["role"] == "candidate":
            environment["OPENRAMBLE_TEMP_MODEL_WINDOW_SECONDS"] = str(config["shape"])
        else:
            environment.pop("OPENRAMBLE_TEMP_MODEL_WINDOW_SECONDS", None)
        self.stderr = stderr_path.open("x", encoding="utf-8")
        self.wire = wire_path.open("x", encoding="utf-8")
        self.process = subprocess.Popen(
            [str(BINARY), "serve-jsonl"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr,
            text=True,
            bufsize=1,
            env=environment,
        )

    def request(self, payload: dict) -> dict:
        if self.process.stdin is None or self.process.stdout is None:
            raise RuntimeError("runner pipes unavailable")
        request = dict(payload)
        request["id"] = self.next_id
        self.next_id += 1
        self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(f"runner EOF, return={self.process.poll()}")
        self.wire.write(line)
        self.wire.flush()
        response = json.loads(line)
        if response.get("id") != request["id"] or response.get("ok") is not True:
            raise RuntimeError(f"runner request failed for command={request.get('command')}")
        if response.get("protocol_version") != 1:
            raise RuntimeError("protocol version mismatch")
        return response

    def shutdown(self) -> dict | None:
        response = None
        try:
            if self.process.poll() is None:
                response = self.request({"command": "shutdown"})
                self.process.wait(timeout=20)
        finally:
            if self.process.poll() is None:
                self.process.terminate()
                self.process.wait(timeout=20)
            self.wire.close()
            self.stderr.close()
        return response


def validate_load(response: dict, config: dict) -> None:
    expected = {
        "encoder": "palettized6bit",
        "encoder_placement": "automatic",
        "mel_chunk_context": False,
        "dual_decode": False,
        "max_tokens_per_chunk": 600,
        "parallel_chunk_concurrency": 4,
        "vocabulary_enabled": True,
        "vocabulary_scheduling": "candidateRegions",
        "vocabulary_terms": 28,
        "vocabulary_similarity": 0.65,
        "vocabulary_bias_weight": 3.0,
        "temp_model_window_seconds": str(config["shape"]) if config["role"] == "candidate" else None,
    }
    settings = response.get("effective_settings")
    if not isinstance(settings, dict):
        raise RuntimeError("load response missing effective settings")
    for key, value in expected.items():
        if settings.get(key) != value:
            raise RuntimeError(f"effective setting mismatch for {key}: {settings.get(key)!r} != {value!r}")
    if response.get("model", {}).get("engine_directory") != str(config["model"]):
        raise RuntimeError("loaded model directory mismatch")
    if response.get("vocabulary_model", {}).get("engine_directory") != str(VOCAB):
        raise RuntimeError("loaded vocabulary directory mismatch")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--variant", choices=tuple(VARIANTS), required=True)
    args = parser.parse_args()
    variant = args.variant
    config = VARIANTS[variant]
    preregistration = json.loads(PREREGISTRATION.read_text(encoding="utf-8"))
    if preregistration.get("inference_allowed") is not True:
        print("inference_allowed=false; frozen prior-evidence hard gate rejected this hypothesis")
        return 78
    if preregistration.get("status") != "armed_and_sealed_before_inference":
        print("preregistration is not armed")
        return 78
    lineage = json.loads(LINEAGE.read_text())
    manifest = json.loads(MANIFEST.read_text())
    if lineage.get("status") != "sealed_before_any_coreml_load_or_inference":
        raise RuntimeError("artifact lineage is not sealed")
    if sha(BINARY) != lineage["runner"]["binary_sha256"]:
        raise RuntimeError("runner binary changed after seal")
    if sha(CONFIG) != lineage["runner"]["product_config_sha256"]:
        raise RuntimeError("product config changed after seal")
    if sha(MANIFEST) != lineage["frozen_inputs"]["manifest_sha256"]:
        raise RuntimeError("manifest changed after seal")
    fixtures = sorted(manifest["fixtures"], key=lambda f: f["id"])
    raw = ROOT / "raw"
    logs = ROOT / "logs"
    metadata_dir = ROOT / "run-metadata"
    for directory in (raw, logs, metadata_dir):
        directory.mkdir(parents=True, exist_ok=True)
    paths = {
        "primary": raw / f"{variant}.primary.jsonl",
        "duplicate": raw / f"{variant}.duplicate.jsonl",
        "smoke": raw / f"{variant}.smoke.jsonl",
        "wire": raw / f"{variant}.wire.jsonl",
        "stderr": logs / f"{variant}.stderr.log",
        "metadata": metadata_dir / f"{variant}.json",
        "receipt": metadata_dir / f"{variant}.completion.json",
    }
    if any(path.exists() for path in paths.values()):
        raise RuntimeError(f"refusing to overwrite existing protocol artifacts for {variant}")

    engine = Engine(variant, config, paths["stderr"], paths["wire"])
    if config["role"] == "shipping":
        selected = lineage["shipping"]
    else:
        selected = lineage["candidates"][config["lineage_key"]]
    if tree_sha(config["model"]) != selected["model"]["tree_sha256"]:
        engine.shutdown()
        raise RuntimeError("model tree changed after seal")
    metadata = {
        "schema_version": 1,
        "status": "sealed_after_process_spawn_and_before_load_or_inference",
        "role": config["role"],
        "variant": variant,
        "shape_seconds": config["shape"],
        "model_directory": str(config["model"]),
        "model_tree_sha256": selected["model"]["tree_sha256"],
        "encoder_mil_sha256": selected["encoder"]["model_mil_sha256"],
        "preprocessor_mil_sha256": selected["preprocessor"]["model_mil_sha256"],
        "shared_weight_artifact_sha256": lineage["shipping"]["shared_encoder_weight_sha256"],
        "runner_binary_sha256": lineage["runner"]["binary_sha256"],
        "orchestrator_path": str(Path(__file__)),
        "orchestrator_sha256": sha(Path(__file__)),
        "product_config_sha256": lineage["runner"]["product_config_sha256"],
        "source_commit": lineage["runner"]["openramble_source"]["commit"],
        "source_overlay_sha256": lineage["runner"]["openramble_source"]["effective_overlay_sha256"],
        "fluid_audio_source_commit": lineage["runner"]["fluid_audio_source"]["commit"],
        "fluid_audio_overlay_sha256": lineage["runner"]["fluid_audio_source"]["effective_overlay_sha256"],
        "artifact_lineage_sha256": sha(LINEAGE),
        "manifest_sha256": sha(MANIFEST),
        "vocabulary_configured": True,
        "vocabulary_terms": 28,
        "language_hints_from_manifest": True,
        "fixture_order": "manifest_id_ascending",
        "fixture_count": len(fixtures),
        "prewarm_protocol": "one_process_per_model; explicit prewarm; 4-fixture structural smoke; complete primary pass; complete duplicate pass",
        "process_id": engine.process.pid,
        "started_at_utc": utcnow(),
        "completed_at_utc": "recorded_in_separate_immutable_completion_receipt",
        "quality_outputs_inspected_before_seal": False,
        "candidate_packaging": "standalone_static_12.5_preprocessor_plus_encoder" if config["role"] == "candidate" else "shipping_installed",
    }
    atomic_json(paths["metadata"], metadata, 0o444)
    metadata_sha = sha(paths["metadata"])
    completed = {"smoke": 0, "primary": 0, "duplicate": 0}
    shutdown = None
    failure = None
    try:
        load = engine.request({"command": "load"})
        validate_load(load, config)
        prewarm = engine.request({"command": "prewarm"})
        if prewarm.get("command") != "prewarm":
            raise RuntimeError("invalid prewarm response")

        with paths["smoke"].open("x", encoding="utf-8") as handle:
            for smoke in SMOKE:
                source = Path(smoke["path"])
                if sha(source) != smoke["source_sha256"]:
                    raise RuntimeError(f"smoke source changed: {smoke['id']}")
                preload = engine.request(
                    {"command": "preload", "key": f"smoke:{smoke['id']}", "path": str(source), "format": "audio"}
                )
                response = engine.request(
                    {"command": "run", "key": f"smoke:{smoke['id']}", "language": smoke["language"]}
                )
                duration = response["sample_count"] / 16000.0
                failures = validate_result(response, duration)
                if failures:
                    raise RuntimeError(f"smoke structural corruption: {smoke['id']}: {failures}")
                response.update({"fixture_id": smoke["id"], "language": smoke["language"], "source_pcm_sha256": preload["pcm_f32le_sha256"], "emission_validation_failures": []})
                handle.write(json.dumps(response, ensure_ascii=False, sort_keys=True) + "\n")
                handle.flush()
                completed["smoke"] += 1

        for fixture in fixtures:
            preload = engine.request(
                {"command": "preload", "key": fixture["id"], "path": fixture["pcm_path"], "format": "f32le"}
            )
            if preload.get("pcm_f32le_sha256") != fixture["pcm_f32le_sha256"]:
                raise RuntimeError(f"PCM hash mismatch: {fixture['id']}")
            if preload.get("sample_count") != fixture["sample_count"]:
                raise RuntimeError(f"sample-count mismatch: {fixture['id']}")

        for pass_name in ("primary", "duplicate"):
            with paths[pass_name].open("x", encoding="utf-8") as handle:
                for fixture in fixtures:
                    response = engine.request(
                        {"command": "run", "key": fixture["id"], "language": fixture["language_hint"]}
                    )
                    failures = validate_result(response, fixture["duration_seconds"])
                    if response.get("pcm_f32le_sha256") != fixture["pcm_f32le_sha256"]:
                        failures.append("result PCM hash mismatch")
                    if response.get("sample_count") != fixture["sample_count"]:
                        failures.append("result sample-count mismatch")
                    if failures:
                        raise RuntimeError(f"full-pass structural corruption: {fixture['id']}: {failures}")
                    response.update(
                        {
                            "fixture_id": fixture["id"],
                            "language": fixture["language_hint"],
                            "emission_validation_failures": [],
                        }
                    )
                    handle.write(json.dumps(response, ensure_ascii=False, sort_keys=True) + "\n")
                    handle.flush()
                    completed[pass_name] += 1
    except Exception as error:
        failure = f"{type(error).__name__}: {error}"
    finally:
        try:
            shutdown = engine.shutdown()
        except Exception as error:
            failure = failure or f"shutdown {type(error).__name__}: {error}"

    receipt = {
        "schema_version": 1,
        "variant": variant,
        "process_id": metadata["process_id"],
        "run_metadata_sha256": metadata_sha,
        "completed_at_utc": utcnow(),
        "completed": completed,
        "required": {"smoke": 4, "primary": len(fixtures), "duplicate": len(fixtures)},
        "shutdown_ok": isinstance(shutdown, dict) and shutdown.get("ok") is True,
        "process_return_code": engine.process.returncode,
        "failure": failure,
        "artifact_sha256": {
            key: sha(paths[key]) if paths[key].exists() else None
            for key in ("smoke", "primary", "duplicate", "wire", "stderr", "metadata")
        },
    }
    receipt["complete"] = (
        failure is None
        and receipt["shutdown_ok"]
        and completed == receipt["required"]
        and receipt["process_return_code"] == 0
    )
    atomic_json(paths["receipt"], receipt, 0o444)
    print(f"variant={variant}")
    print(f"complete={str(receipt['complete']).lower()}")
    print(f"completed={json.dumps(completed, sort_keys=True)}")
    print(f"run_metadata_sha256={metadata_sha}")
    print(f"completion_sha256={sha(paths['receipt'])}")
    if failure:
        print(f"failure={failure}")
    return 0 if receipt["complete"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
