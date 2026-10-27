"""Convert moondream/parakeet-ultra (transformers layout) to parakeet-mlx's layout.

    python -I convert_ultra_to_mlx.py

Run it with the interpreter of ~/Library/Caches/OpenRambleSpike/parakeet-mlx/venv.
Reads   $SPIKE_ROOT/parakeet-mlx/models/ultra-source/{model.safetensors,tokenizer.json}
        $SPIKE_ROOT/parakeet-mlx/models/v3/config.json   (NeMo config of v3, same architecture)
Writes  $SPIKE_ROOT/parakeet-mlx/models/ultra/{model.safetensors,config.json}

Ultra is a post-training of Parakeet TDT 0.6B v3 with the same architecture and
vocabulary, published in the transformers layout. This renames every tensor to
the NeMo name that mlx-community's v3 conversion uses, moves convolution
weights to MLX's channels-last layout, adds the two LSTM bias vectors (MLX's
LSTM has one), and drops BatchNorm's counters and Moondream's six vad_head
tensors, which transcription does not use. Values are copied unchanged
(float16 stays float16, float32 stays float32). It checks that the result has
exactly v3's tensor names and shapes, and that Ultra's vocabulary equals v3's.
"""

import json
import os
import re
import shutil
from pathlib import Path

import mlx.core as mx

ROOT = Path(os.environ.get("SPIKE_ROOT", Path.home() / "Library/Caches/OpenRambleSpike")) / "parakeet-mlx/models"
SOURCE, V3, OUT = ROOT / "ultra-source", ROOT / "v3", ROOT / "ultra"

RENAMES = [
    (r"^decoder\.embedding\.weight$", "decoder.prediction.embed.weight"),
    (r"^decoder\.lstm\.weight_ih_l(\d)$", r"decoder.prediction.dec_rnn.lstm.\1.Wx"),
    (r"^decoder\.lstm\.weight_hh_l(\d)$", r"decoder.prediction.dec_rnn.lstm.\1.Wh"),
    (r"^decoder\.decoder_projector\.", "joint.pred."),
    (r"^encoder_projector\.", "joint.enc."),
    (r"^joint\.head\.", "joint.joint_net.2."),
    (r"^encoder\.subsampling\.layers\.(\d+)\.", r"encoder.pre_encode.conv.\1."),
    (r"^encoder\.subsampling\.linear\.", "encoder.pre_encode.out."),
    (r"\.conv\.norm\.", ".conv.batch_norm."),
    (r"\.self_attn\.q_proj\.", ".self_attn.linear_q."),
    (r"\.self_attn\.k_proj\.", ".self_attn.linear_k."),
    (r"\.self_attn\.v_proj\.", ".self_attn.linear_v."),
    (r"\.self_attn\.o_proj\.", ".self_attn.linear_out."),
    (r"\.self_attn\.relative_k_proj\.", ".self_attn.linear_pos."),
    (r"\.self_attn\.bias_u$", ".self_attn.pos_bias_u"),
    (r"\.self_attn\.bias_v$", ".self_attn.pos_bias_v"),
]


def rename(key: str) -> str:
    for pattern, replacement in RENAMES:
        key = re.sub(pattern, replacement, key)
    return key


def main() -> None:
    src = mx.load(str(SOURCE / "model.safetensors"))
    out: dict[str, mx.array] = {}
    for key, value in src.items():
        if key.startswith("vad_head.") or key.endswith("num_batches_tracked"):
            continue
        m = re.match(r"^decoder\.lstm\.bias_(ih|hh)_l(\d)$", key)
        if m:
            if m.group(1) == "ih":
                other = src[f"decoder.lstm.bias_hh_l{m.group(2)}"]
                out[f"decoder.prediction.dec_rnn.lstm.{m.group(2)}.bias"] = (
                    value.astype(mx.float32) + other.astype(mx.float32)
                )
            continue
        name = rename(key)
        if value.ndim == 4:  # Conv2d [out, in, kh, kw] -> MLX [out, kh, kw, in]
            value = value.transpose(0, 2, 3, 1)
        elif value.ndim == 3:  # Conv1d [out, in, k] -> MLX [out, k, in]
            value = value.transpose(0, 2, 1)
        out[name] = value

    # Same tensor names and shapes as mlx-community's v3 conversion.
    reference = mx.load(str(V3 / "model.safetensors"))
    missing = sorted(set(reference) - set(out))
    extra = sorted(set(out) - set(reference))
    wrong = sorted(k for k in set(out) & set(reference) if out[k].shape != reference[k].shape)
    if missing or extra or wrong:
        raise SystemExit(f"layout mismatch: missing={missing[:5]} extra={extra[:5]} shape={wrong[:5]}")
    del reference

    # Same vocabulary as v3.
    config = json.load(open(V3 / "config.json"))
    vocab_v3 = config["joint"]["vocabulary"]
    tok = json.load(open(SOURCE / "tokenizer.json"))["model"]["vocab"]
    pieces = [p[0] for p in tok] if isinstance(tok, list) else [p for p, _ in sorted(tok.items(), key=lambda kv: kv[1])]
    if pieces[: len(vocab_v3)] != vocab_v3:
        raise SystemExit("Ultra's vocabulary differs from v3's")

    OUT.mkdir(parents=True, exist_ok=True)
    mx.save_safetensors(str(OUT / "model.safetensors"), out)
    shutil.copy(V3 / "config.json", OUT / "config.json")
    print(f"wrote {len(out)} tensors to {OUT}")


if __name__ == "__main__":
    main()
