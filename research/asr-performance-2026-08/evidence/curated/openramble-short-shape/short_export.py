#!/usr/bin/env python3
"""TEMP-ONLY 7.5 s Parakeet TDT v3 Core ML frontend exporter.

This intentionally exports only the waveform preprocessor and FastConformer
encoder.  The production decoder and single-step joint keep their existing
shape contracts because the encoder hidden dimension remains 1024.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import soundfile as sf
import torch
import nemo.collections.asr as nemo_asr
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig,
    OpPalettizerConfig,
    OptimizationConfig,
    linear_quantize_weights,
    palettize_weights,
)

from individual_components import EncoderWrapper, ExportSettings, PreprocessorWrapper, _coreml_convert


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def package_files(path: Path) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for item in sorted(path.rglob("*")):
        if item.is_file():
            result.append(
                {
                    "path": str(item.relative_to(path)),
                    "bytes": item.stat().st_size,
                    "sha256": sha256_file(item),
                }
            )
    return result


def load_trace_audio(path: Path, sample_rate: int, sample_count: int) -> torch.Tensor:
    samples, actual_rate = sf.read(str(path), dtype="float32")
    if actual_rate != sample_rate:
        raise ValueError(f"trace sample rate {actual_rate} != {sample_rate}")
    if samples.ndim > 1:
        samples = samples[:, 0]
    if samples.size < sample_count:
        samples = np.pad(samples, (0, sample_count - samples.size))
    else:
        samples = samples[:sample_count]
    return torch.from_numpy(samples).reshape(1, sample_count).to(dtype=torch.float32)


def save_package(model: ct.models.MLModel, path: Path, description: str) -> None:
    if path.exists():
        shutil.rmtree(path)
    model.short_description = description
    model.author = "Fluid Inference; temporary OpenRamble shape experiment"
    model.save(str(path))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nemo-path", type=Path, required=True)
    parser.add_argument("--trace-audio", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=7.5)
    parser.add_argument(
        "--enumerated-seconds",
        type=float,
        nargs="*",
        default=None,
        help="Optional finite waveform buckets; --seconds selects the default shape.",
    )
    parser.add_argument("--upstream-revision", required=True)
    parser.add_argument("--mobius-revision", required=True)
    args = parser.parse_args()

    torch.manual_seed(0)
    started = time.perf_counter()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    load_started = time.perf_counter()
    model = nemo_asr.models.EncDecRNNTBPEModel.restore_from(
        str(args.nemo_path), map_location="cpu"
    )
    model.eval()
    checkpoint_load_seconds = time.perf_counter() - load_started

    sample_rate = int(model.cfg.preprocessor.sample_rate)
    shape_seconds = sorted(set(args.enumerated_seconds or [args.seconds]))
    if args.seconds not in shape_seconds:
        raise ValueError("--seconds must be present in --enumerated-seconds")
    sample_counts = [round(seconds * sample_rate) for seconds in shape_seconds]
    default_sample_count = round(args.seconds * sample_rate)
    trace_sample_count = max(sample_counts)
    audio = load_trace_audio(args.trace_audio, sample_rate, trace_sample_count)
    audio_length = torch.tensor([trace_sample_count], dtype=torch.int32)
    preprocessor = PreprocessorWrapper(model.preprocessor.eval()).cpu()
    encoder = EncoderWrapper(model.encoder.eval()).cpu()

    references = []
    with torch.inference_mode():
        for seconds, sample_count in zip(shape_seconds, sample_counts):
            shape_audio = load_trace_audio(args.trace_audio, sample_rate, sample_count)
            shape_audio_length = torch.tensor([sample_count], dtype=torch.int32)
            shape_mel, shape_mel_length = preprocessor(shape_audio, shape_audio_length)
            shape_mel_length = shape_mel_length.to(dtype=torch.int32)
            shape_encoder, shape_encoder_length = encoder(shape_mel, shape_mel_length)
            references.append(
                {
                    "seconds": seconds,
                    "sample_count": sample_count,
                    "audio": shape_audio,
                    "audio_length": shape_audio_length,
                    "mel": shape_mel,
                    "mel_length": shape_mel_length,
                    "encoder": shape_encoder,
                    "encoder_length": shape_encoder_length,
                }
            )

    trace_reference = references[-1]
    mel_reference = trace_reference["mel"]
    mel_length_reference = trace_reference["mel_length"]
    encoder_reference = trace_reference["encoder"]
    encoder_length_reference = trace_reference["encoder_length"]

    # Drop the inference-tensor flag before tracing.
    mel_reference = mel_reference.clone()
    mel_length_reference = mel_length_reference.clone()
    encoder_reference = encoder_reference.clone()
    encoder_length_reference = encoder_length_reference.clone()

    settings = ExportSettings(
        output_dir=args.output_dir,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        deployment_target=ct.target.iOS17,
        compute_precision=None,
        max_audio_seconds=max(shape_seconds),
        max_symbol_steps=1,
    )

    pre_trace_started = time.perf_counter()
    traced_preprocessor = torch.jit.trace(
        preprocessor, (audio, audio_length), strict=False
    ).eval()
    pre_trace_seconds = time.perf_counter() - pre_trace_started
    pre_convert_started = time.perf_counter()
    if len(sample_counts) == 1:
        preprocessor_input_shape = (1, sample_counts[0])
    else:
        preprocessor_input_shape = ct.EnumeratedShapes(
            shapes=[(1, count) for count in sample_counts],
            default=(1, default_sample_count),
        )
    preprocessor_model = _coreml_convert(
        traced_preprocessor,
        [
            ct.TensorType(
                name="audio_signal", shape=preprocessor_input_shape, dtype=np.float32
            ),
            ct.TensorType(name="audio_length", shape=(1,), dtype=np.int32),
        ],
        [
            ct.TensorType(name="mel", dtype=np.float32),
            ct.TensorType(name="mel_length", dtype=np.int32),
        ],
        settings,
        compute_units_override=ct.ComputeUnit.CPU_ONLY,
    )
    pre_convert_seconds = time.perf_counter() - pre_convert_started
    pre_quant_started = time.perf_counter()
    preprocessor_model = linear_quantize_weights(
        preprocessor_model,
        OptimizationConfig(
            global_config=OpLinearQuantizerConfig(
                mode="linear", granularity="per_channel"
            )
        ),
    )
    pre_quant_seconds = time.perf_counter() - pre_quant_started
    preprocessor_path = args.output_dir / "Preprocessor.mlpackage"
    save_package(
        preprocessor_model,
        preprocessor_path,
        f"TEMP Parakeet int8 preprocessor ({shape_seconds} s windows)",
    )

    enc_trace_started = time.perf_counter()
    traced_encoder = torch.jit.trace(
        encoder, (mel_reference, mel_length_reference), strict=False
    ).eval()
    enc_trace_seconds = time.perf_counter() - enc_trace_started
    enc_convert_started = time.perf_counter()
    mel_shapes = [tuple(int(x) for x in reference["mel"].shape) for reference in references]
    default_mel_shape = next(
        shape
        for reference, shape in zip(references, mel_shapes)
        if reference["sample_count"] == default_sample_count
    )
    if len(mel_shapes) == 1:
        encoder_input_shape = mel_shapes[0]
    else:
        encoder_input_shape = ct.EnumeratedShapes(
            shapes=mel_shapes,
            default=default_mel_shape,
        )
    encoder_model = _coreml_convert(
        traced_encoder,
        [
            ct.TensorType(
                name="mel", shape=encoder_input_shape, dtype=np.float32
            ),
            ct.TensorType(name="mel_length", shape=(1,), dtype=np.int32),
        ],
        [
            ct.TensorType(name="encoder", dtype=np.float32),
            ct.TensorType(name="encoder_length", dtype=np.int32),
        ],
        settings,
        compute_units_override=ct.ComputeUnit.CPU_ONLY,
    )
    enc_convert_seconds = time.perf_counter() - enc_convert_started
    enc_quant_started = time.perf_counter()
    encoder_model = palettize_weights(
        encoder_model,
        OptimizationConfig(
            global_config=OpPalettizerConfig(mode="kmeans", nbits=6)
        ),
    )
    enc_quant_seconds = time.perf_counter() - enc_quant_started
    encoder_path = args.output_dir / "Encoder.mlpackage"
    save_package(
        encoder_model,
        encoder_path,
        f"TEMP Parakeet 6-bit encoder ({shape_seconds} s windows)",
    )

    metadata = {
        "schema_version": 1,
        "temporary_prototype": True,
        "host": {
            "machine": platform.machine(),
            "macos": platform.mac_ver()[0],
            "python": platform.python_version(),
            "torch": torch.__version__,
            "coremltools": ct.__version__,
        },
        "sources": {
            "nemo_path": str(args.nemo_path),
            "nemo_sha256": sha256_file(args.nemo_path),
            "upstream_revision": args.upstream_revision,
            "mobius_revision": args.mobius_revision,
        },
        "contract": {
            "default_seconds": args.seconds,
            "sample_rate": sample_rate,
            "enumerated": len(references) > 1,
            "shapes": [
                {
                    "seconds": reference["seconds"],
                    "audio_shape": list(reference["audio"].shape),
                    "mel_shape": list(reference["mel"].shape),
                    "mel_length": int(reference["mel_length"][0]),
                    "encoder_shape": list(reference["encoder"].shape),
                    "encoder_length": int(reference["encoder_length"][0]),
                    "hidden_size_compatible_with_shipping_joint": int(
                        reference["encoder"].shape[1]
                    )
                    == 1024,
                }
                for reference in references
            ],
        },
        "build_seconds": {
            "checkpoint_load": checkpoint_load_seconds,
            "preprocessor_trace": pre_trace_seconds,
            "preprocessor_convert": pre_convert_seconds,
            "preprocessor_quantize": pre_quant_seconds,
            "encoder_trace": enc_trace_seconds,
            "encoder_convert": enc_convert_seconds,
            "encoder_quantize": enc_quant_seconds,
            "total": time.perf_counter() - started,
        },
        "artifacts": {
            "preprocessor": package_files(preprocessor_path),
            "encoder": package_files(encoder_path),
        },
    }
    metadata_path = args.output_dir / "prototype-metadata.json"
    metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    print(json.dumps(metadata, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
