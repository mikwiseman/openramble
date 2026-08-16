#!/usr/bin/env python3
"""CPU-only independent Python↔Swift execution-identity cross-check."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

from dual_cache_harness.real_preflight import load_real_identity
from dual_cache_harness.schema import ExecutionIdentity, canonical_json_bytes


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", type=Path, required=True)
    arguments = parser.parse_args()
    worker = arguments.worker.resolve(strict=True)
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        model = root / "model"
        vocabulary_model = root / "vocabulary"
        model.mkdir()
        vocabulary_model.mkdir()
        (model / "model.bin").write_bytes(b"dummy-main-model")
        (vocabulary_model / "model.bin").write_bytes(b"dummy-vocabulary-model")
        vocabulary = json.loads(
            subprocess.check_output(
                [str(worker), "--print-developer-vocabulary"], text=True
            )
        )
        token = "identity-only-no-model-execution"
        spec = {
            "schema_version": 1,
            "code_revision": "cpu-identity-crosscheck",
            "model_directory": str(model),
            "vocabulary_model_directory": str(vocabulary_model),
            "language_hint": "ru",
            "authorization_token_sha256": hashlib.sha256(token.encode()).hexdigest(),
            "configuration": {
                "model_version": "v3",
                "mel_chunk_context": False,
                "encoder_variant": "palettized6bit",
                "encoder_placement": "automatic",
                "dual_decode_arbitration": False,
                "max_tokens_per_chunk": 600,
                "parallel_chunk_concurrency": 4,
                "vocabulary_scheduling": "candidateRegions",
                "ml_compute_units": "all",
            },
            "vocabulary": vocabulary,
        }
        spec_path = root / "spec.json"
        spec_path.write_bytes(canonical_json_bytes(spec))
        python_identity, _ = load_real_identity(worker=worker, spec_path=spec_path)
        swift_identity = ExecutionIdentity.from_dict(
            json.loads(
                subprocess.check_output(
                    [str(worker), "--spec", str(spec_path), "--print-identity"],
                    text=True,
                )
            )
        )
        if python_identity != swift_identity:
            print(
                json.dumps(
                    {
                        "ok": False,
                        "python": python_identity.to_dict(),
                        "swift": swift_identity.to_dict(),
                    },
                    indent=2,
                    sort_keys=True,
                )
            )
            return 1
        print(
            json.dumps(
                {
                    "ok": True,
                    "canonical_identity_sha256": python_identity.canonical_sha256,
                    "worker_sha256": hashlib.sha256(worker.read_bytes()).hexdigest(),
                    "model_loaded": False,
                },
                sort_keys=True,
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
