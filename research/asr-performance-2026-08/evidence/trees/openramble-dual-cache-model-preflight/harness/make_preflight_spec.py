#!/usr/bin/env python3
"""Create the reviewed real-worker spec without loading a model."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

from dual_cache_harness.schema import canonical_json_bytes


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def make_spec(
    *,
    worker: Path,
    model_directory: Path,
    vocabulary_directory: Path,
    token: str,
    code_revision: str | None,
) -> dict:
    worker = worker.resolve(strict=True)
    model_directory = model_directory.resolve(strict=True)
    vocabulary_directory = vocabulary_directory.resolve(strict=True)
    vocabulary = json.loads(
        subprocess.check_output(
            [str(worker), "--print-developer-vocabulary"], text=True
        )
    )
    # Re-canonicalization rejects accidental floating JSON. Similarity and
    # weight must remain exact IEEE bit integers across Python and Swift.
    canonical_json_bytes(vocabulary)
    return {
        "schema_version": 1,
        "code_revision": code_revision
        or f"dual-cache-worker:{sha256_file(worker)}",
        "model_directory": str(model_directory),
        "vocabulary_model_directory": str(vocabulary_directory),
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--model-directory", type=Path, required=True)
    parser.add_argument("--vocabulary-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--code-revision")
    parser.add_argument(
        "--authorization-token-env", default="DCHF_COREML_GO_TOKEN"
    )
    arguments = parser.parse_args()
    token = os.environ.get(arguments.authorization_token_env)
    if not token:
        parser.error(f"{arguments.authorization_token_env} must be set after explicit GO")
    value = make_spec(
        worker=arguments.worker,
        model_directory=arguments.model_directory,
        vocabulary_directory=arguments.vocabulary_directory,
        token=token,
        code_revision=arguments.code_revision,
    )
    data = canonical_json_bytes(value) + b"\n"
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=arguments.output.name + ".",
        dir=arguments.output.parent,
    )
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, arguments.output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(
        json.dumps(
            {
                "ok": True,
                "output": str(arguments.output),
                "spec_sha256": hashlib.sha256(data).hexdigest(),
                "worker_sha256": sha256_file(arguments.worker),
                "model_loaded": False,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
