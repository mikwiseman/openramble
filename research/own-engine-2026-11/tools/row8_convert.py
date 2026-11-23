"""Store every quantized matrix of a model file as 8-bit numbers with one
scale per row.

    row8_convert.py IN.gguf OUT.gguf

The M4's matrix unit multiplies 8-bit numbers with one scale for a whole row
(ledger K8). The files the app ships keep one scale for every 32 numbers
(Q8_0) or a 4-bit layout with scales and minimums every 32 (Q4_K). This
writes a copy in which every Q4_K and Q8_0 matrix is a Q8_0 matrix whose
blocks in one row all carry the same scale, the row's largest magnitude over
127, and whose numbers are rounded to it. The engine's Q8_0 kernels then
compute what a row-scaled 8-bit kernel computes, so the word-error gate
measures the layout before any new kernel exists.

The metadata and every other tensor are copied as they are. Prints, per
tensor, how far its weights moved: the root mean square of the change over
that of the weights.
"""
import struct
import sys

import numpy as np

F32, F16, Q8_0, Q4_K = 0, 1, 8, 12
Q8_DTYPE = np.dtype([("d", "<f2"), ("q", "i1", (32,))])
Q4K_DTYPE = np.dtype([("d", "<f2"), ("dmin", "<f2"), ("scales", "u1", (12,)), ("qs", "u1", (128,))])
SIZE = {F32: (1, 4), F16: (1, 2), Q8_0: (32, 34), Q4_K: (256, 144)}


def read(f, fmt):
    return struct.unpack(fmt, f.read(struct.calcsize(fmt)))


def read_str(f):
    (n,) = read(f, "<Q")
    return f.read(n).decode("utf-8", "replace")


SCALAR = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}


def read_value(f, kind):
    if kind in SCALAR:
        return read(f, "<" + SCALAR[kind])[0]
    if kind == 8:
        return read_str(f)
    if kind == 9:
        (inner,) = read(f, "<I")
        (n,) = read(f, "<Q")
        return [read_value(f, inner) for _ in range(n)]
    raise ValueError(f"unknown value type {kind}")


def parse(data):
    """The metadata bytes, the alignment and the tensors of a GGUF file."""
    import io
    f = io.BytesIO(data)
    if f.read(4) != b"GGUF":
        raise SystemExit("not a GGUF file")
    read(f, "<I")
    (tensors,) = read(f, "<Q")
    (pairs,) = read(f, "<Q")
    meta = {}
    for _ in range(pairs):
        key = read_str(f)
        (kind,) = read(f, "<I")
        meta[key] = read_value(f, kind)
    head = data[:f.tell()]
    infos = []
    for _ in range(tensors):
        name = read_str(f)
        (dims,) = read(f, "<I")
        shape = read(f, f"<{dims}Q")
        (kind,) = read(f, "<I")
        (offset,) = read(f, "<Q")
        infos.append([name, shape, kind, offset])
    align = meta.get("general.alignment", 32)
    base = (f.tell() + align - 1) // align * align
    return head, align, [(n, s, k, base + o) for n, s, k, o in infos]


def nbytes(shape, kind):
    per, size = SIZE[kind]
    return int(np.prod(shape)) // per * size


def q4k_weights(raw, count):
    """ggml's dequantize_row_q4_K, for whole tensors at once."""
    b = np.frombuffer(raw, dtype=Q4K_DTYPE, count=count // 256)
    s = b["scales"].astype(np.uint16)
    sc = np.empty((len(b), 8), np.float32)
    mn = np.empty((len(b), 8), np.float32)
    sc[:, :4], mn[:, :4] = s[:, 0:4] & 63, s[:, 4:8] & 63
    sc[:, 4:] = (s[:, 8:12] & 0xF) | ((s[:, 0:4] >> 6) << 4)
    mn[:, 4:] = (s[:, 8:12] >> 4) | ((s[:, 4:8] >> 6) << 4)
    d = b["d"].astype(np.float32)[:, None] * sc
    m = b["dmin"].astype(np.float32)[:, None] * mn
    qs = b["qs"].reshape(len(b), 4, 32)
    nib = np.empty((len(b), 8, 32), np.float32)
    nib[:, 0::2], nib[:, 1::2] = qs & 0xF, qs >> 4
    return (d[..., None] * nib - m[..., None]).reshape(-1)


def q8_weights(raw, count):
    b = np.frombuffer(raw, dtype=Q8_DTYPE, count=count // 32)
    return (b["q"].astype(np.float32) * b["d"].astype(np.float32)[:, None]).reshape(-1)


def row_scaled(flat, row):
    """Q8_0 blocks whose scale is the same along each row of `row` numbers."""
    w = flat.reshape(-1, row)
    scale = (np.abs(w).max(axis=1) / 127.0).astype(np.float16)
    stored = scale.astype(np.float32)
    safe = np.where(stored > 0, stored, 1.0)
    numbers = np.clip(np.rint(w / safe[:, None]), -127, 127).astype(np.int8)
    out = np.empty(w.size // 32, dtype=Q8_DTYPE)
    out["d"] = np.repeat(scale, row // 32)
    out["q"] = numbers.reshape(-1, 32)
    after = numbers.astype(np.float32) * stored[:, None]
    moved = float(np.sqrt(np.mean((after - w) ** 2) / max(np.mean(w ** 2), 1e-30)))
    return out.tobytes(), moved


def main():
    data = open(sys.argv[1], "rb").read()
    head, align, tensors = parse(data)
    infos, blobs = b"", []
    offset = 0
    for name, shape, kind, start in tensors:
        raw = data[start:start + nbytes(shape, kind)]
        count = int(np.prod(shape))
        if kind in (Q4_K, Q8_0) and shape[0] % 32 == 0:
            weights = q4k_weights(raw, count) if kind == Q4_K else q8_weights(raw, count)
            raw, moved = row_scaled(weights, shape[0])
            print(f"{name}\t{list(shape)}\t{'Q4_K' if kind == Q4_K else 'Q8_0'}\tweights moved {100 * moved:.2f}%")
            kind = Q8_0
        encoded = name.encode()
        infos += struct.pack("<Q", len(encoded)) + encoded + struct.pack("<I", len(shape))
        infos += struct.pack(f"<{len(shape)}Q", *shape) + struct.pack("<IQ", kind, offset)
        blobs.append((offset, raw))
        offset = (offset + len(raw) + align - 1) // align * align
    with open(sys.argv[2], "wb") as out:
        out.write(head + infos)
        out.write(b"\0" * ((-out.tell()) % align))
        base = out.tell()
        for start, raw in blobs:
            out.write(b"\0" * (base + start - out.tell()))
            out.write(raw)
    print(f"written {sys.argv[2]}")


if __name__ == "__main__":
    main()
