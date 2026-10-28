"""parakeet-mlx runner for the runtime spike (Apple GPU through MLX).

    python -I parakeet_mlx_runner.py [--model v3|ultra] [--dtype bfloat16|float16|float32]
        [--chunk SECONDS] <manifest.jsonl> <out.jsonl>

Run it with the interpreter of ~/Library/Caches/OpenRambleSpike/parakeet-mlx/venv.
The model is read from a local folder (config.json + model.safetensors); the
Hugging Face hub is never contacted. Weights are cast to --dtype (default
bfloat16, parakeet-mlx's own default) and evaluated before the load clock
stops, so load_seconds is real work, not MLX's lazy graph. The first output row
is {"id": "__load__", "load_seconds": ...}, also printed to stderr; then one
row per manifest row with {"id", "text", "audio_seconds", "wall_seconds"}.
wall_seconds covers mel, encoder and greedy TDT decoding of samples already in
memory; reading the WAV is excluded. --chunk uses parakeet-mlx's own chunked
path (15 s overlap) for files longer than the chunk; without it the whole file
is one pass, the library's default.
"""

import argparse
import json
import os
import sys
import time
import wave
from pathlib import Path

import mlx.core as mx
import numpy as np
import parakeet_mlx.parakeet as parakeet_module
from mlx.utils import tree_flatten, tree_unflatten
from parakeet_mlx.utils import from_config

ROOT = Path(os.environ.get("SPIKE_ROOT", Path.home() / "Library/Caches/OpenRambleSpike"))


def read_wav(path: str) -> np.ndarray:
    with wave.open(path, "rb") as w:
        if w.getframerate() != 16000 or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise SystemExit(f"{path}: expected 16 kHz mono 16-bit PCM")
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
    return pcm.astype(np.float32) / 32768.0


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--model", default="v3", choices=["v3", "ultra"])
    p.add_argument("--dtype", default="bfloat16", choices=["bfloat16", "float16", "float32"])
    p.add_argument("--chunk", type=float, default=None)
    p.add_argument("manifest")
    p.add_argument("out")
    a = p.parse_args()
    dtype = getattr(mx, a.dtype)
    folder = ROOT / "parakeet-mlx/models" / a.model
    rows = [json.loads(line) for line in open(a.manifest) if line.strip()]

    # transcribe() decodes files with ffmpeg; hand it the samples read here instead,
    # as float32 like parakeet-mlx's own load_audio (which ignores its dtype argument).
    preloaded: dict[str, mx.array] = {}
    parakeet_module.load_audio = lambda path, sample_rate, dt: preloaded[str(path)]

    with open(a.out, "w") as out:
        start = time.perf_counter()
        model = from_config(json.load(open(folder / "config.json")))
        model.load_weights(str(folder / "model.safetensors"))
        weights = [(k, v.astype(dtype)) for k, v in tree_flatten(model.parameters())]
        model.update(tree_unflatten(weights))
        mx.eval(model.parameters())
        load = time.perf_counter() - start
        print(f"load_seconds {load:.3f}", file=sys.stderr, flush=True)
        out.write(json.dumps({
            "id": "__load__", "load_seconds": load, "runner": f"parakeet-mlx 0.5.3, mlx {mx.__version__}",
            "model": a.model, "dtype": a.dtype, "device": str(mx.default_device()),
        }) + "\n")
        out.flush()

        for row in rows:
            samples = read_wav(row["path"])
            preloaded[row["path"]] = mx.array(samples)
            mx.eval(preloaded[row["path"]])
            start = time.perf_counter()
            result = model.transcribe(row["path"], dtype=dtype, chunk_duration=a.chunk)
            wall = time.perf_counter() - start
            del preloaded[row["path"]]
            out.write(json.dumps({
                "id": row["id"], "text": result.text,
                "audio_seconds": len(samples) / 16000, "wall_seconds": wall,
            }, ensure_ascii=False) + "\n")
            out.flush()


if __name__ == "__main__":
    main()
