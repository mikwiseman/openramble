#!/usr/bin/env python3
"""TEMP-only materialization of fixed bucket functions from flexible frontends."""

from pathlib import Path
import argparse
import time

import coremltools as ct


def materialize(source: Path, destination: Path, shapes: dict[str, dict[str, tuple[int, ...]]]) -> float:
    started = time.perf_counter()
    model = ct.models.MLModel(
        str(source), compute_units=ct.ComputeUnit.CPU_ONLY, skip_model_load=True
    )
    ct.utils.materialize_dynamic_shape_mlmodel(model, shapes, str(destination))
    return time.perf_counter() - started


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    pre_seconds = materialize(
        args.source_dir / "Preprocessor.mlpackage",
        args.output_dir / "Preprocessor.mlpackage",
        {
            "bucket_7_5": {"audio_signal": (1, 120_000)},
            "bucket_15": {"audio_signal": (1, 240_000)},
        },
    )
    enc_seconds = materialize(
        args.source_dir / "Encoder.mlpackage",
        args.output_dir / "Encoder.mlpackage",
        {
            "bucket_7_5": {"mel": (1, 128, 751)},
            "bucket_15": {"mel": (1, 128, 1501)},
        },
    )
    print({"preprocessor_seconds": pre_seconds, "encoder_seconds": enc_seconds})


if __name__ == "__main__":
    main()
