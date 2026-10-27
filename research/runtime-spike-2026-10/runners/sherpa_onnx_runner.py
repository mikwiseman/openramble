"""sherpa-onnx runner for the runtime spike.

    python -I sherpa_onnx_runner.py [--model v3-int8|v3-fp32|ultra-int8]
        [--provider cpu|coreml] [--threads N] <manifest.jsonl> <out.jsonl>

Run it with the interpreter of ~/Library/Caches/OpenRambleSpike/sherpa-onnx/venv.
The model is loaded once. The first output row is {"id": "__load__",
"load_seconds": ...}, also printed to stderr; then one row per manifest row
with {"id", "text", "audio_seconds", "wall_seconds"}. wall_seconds covers
recognition of samples already in memory; reading the WAV is excluded.
Greedy TDT decoding, no language hint, whole file in one pass.
"""

import argparse
import json
import os
import sys
import time
import wave
from pathlib import Path

import numpy as np
import sherpa_onnx

ROOT = Path(os.environ.get("SPIKE_ROOT", Path.home() / "Library/Caches/OpenRambleSpike"))
MODELS = {
    "v3-int8": ("encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx"),
    "v3-fp32": ("encoder.onnx", "decoder.onnx", "joiner.onnx"),
    "ultra-int8": ("encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx"),
}


def read_wav(path: str) -> np.ndarray:
    with wave.open(path, "rb") as w:
        if w.getframerate() != 16000 or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise SystemExit(f"{path}: expected 16 kHz mono 16-bit PCM")
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
    return pcm.astype(np.float32) / 32768.0


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--model", default="v3-int8", choices=sorted(MODELS))
    p.add_argument("--provider", default="cpu", choices=["cpu", "coreml"])
    p.add_argument("--threads", type=int, default=4)
    p.add_argument("manifest")
    p.add_argument("out")
    a = p.parse_args()

    folder = ROOT / "sherpa-onnx/models" / a.model
    encoder, decoder, joiner = (str(folder / name) for name in MODELS[a.model])
    rows = [json.loads(line) for line in open(a.manifest) if line.strip()]

    with open(a.out, "w") as out:
        start = time.perf_counter()
        recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=encoder,
            decoder=decoder,
            joiner=joiner,
            tokens=str(folder / "tokens.txt"),
            model_type="nemo_transducer",
            decoding_method="greedy_search",
            num_threads=a.threads,
            provider=a.provider,
        )
        load = time.perf_counter() - start
        print(f"load_seconds {load:.3f}", file=sys.stderr, flush=True)
        out.write(json.dumps({
            "id": "__load__", "load_seconds": load, "runner": f"sherpa-onnx {sherpa_onnx.__version__}",
            "model": a.model, "provider": a.provider, "threads": a.threads,
        }) + "\n")
        out.flush()

        for row in rows:
            samples = read_wav(row["path"])
            start = time.perf_counter()
            stream = recognizer.create_stream()
            stream.accept_waveform(16000, samples)
            recognizer.decode_stream(stream)
            text = stream.result.text
            wall = time.perf_counter() - start
            out.write(json.dumps({
                "id": row["id"], "text": text.strip(),
                "audio_seconds": len(samples) / 16000, "wall_seconds": wall,
            }, ensure_ascii=False) + "\n")
            out.flush()


if __name__ == "__main__":
    main()
