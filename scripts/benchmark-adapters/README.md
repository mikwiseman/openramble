# Persistent Handy benchmark adapter

This directory contains a reproducible development patch for a persistent,
backend-only Handy benchmark process. It does **not** reproduce Handy's complete
application, capture, VAD, overlay, or insertion path. Reports produced with it
must say "locally patched Handy backend", never "official Handy app".

The current patch has exactly one valid base:

- repository: `https://github.com/cjpais/Handy.git`
- source commit: `db003f38b1aef4eb967ac3419bebc851d680f71c`
- patch: `handy-persistent-jsonl-db003f3.patch`
- patch SHA-256: `26e86e86df763afe898a128470f40e7679b1943fcfe1483c2896cf27db8edcc4`

The compile and protocol smoke used Handy's catalog entry
`handy-computer/parakeet-tdt-0.6b-v3-gguf/parakeet-tdt-0.6b-v3-Q8_0.gguf`,
catalog revision `85ac09ea12fc4b1112fa76810059364bc6adc9de`, and model SHA-256
`5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7`.
That Q8_0 GGUF is not byte-identical to OpenRamble's Core ML artifact, so a
report must describe the model formats precisely and must not call them the
same model binary.

Build from a fresh checkout. Do not reuse a working tree with unrelated edits.

```bash
git clone https://github.com/cjpais/Handy.git /absolute/path/to/handy-benchmark
git -C /absolute/path/to/handy-benchmark checkout --detach \
  db003f38b1aef4eb967ac3419bebc851d680f71c
git -C /absolute/path/to/handy-benchmark apply --check \
  /absolute/path/to/openramble/scripts/benchmark-adapters/handy-persistent-jsonl-db003f3.patch
git -C /absolute/path/to/handy-benchmark apply \
  /absolute/path/to/openramble/scripts/benchmark-adapters/handy-persistent-jsonl-db003f3.patch
cd /absolute/path/to/handy-benchmark
bun install --frozen-lockfile
bun run tauri build --no-bundle
```

The patch adds `--benchmark-jsonl`. The runner starts the binary once, loads one
model once, explicitly prewarms it, and alternates calls with OpenRamble. The
adapter accepts only canonical `f32le` PCM for the timed in-memory lane. Each
response includes integer monotonic nanoseconds, PCM SHA-256, and raw and
normalized transcript hashes. Model load, fixture clone, protocol I/O, and
hashing are outside that timer. A fixture language is applied only to that
request and never mutates Handy's persisted user settings.

The protocol commands are:

- `load`: load the requested model and report backend/model/settings identity;
- `prewarm`: run one second of silence and require the model to remain resident;
- `preload`: read and retain canonical 16 kHz mono `f32le` PCM;
- `run`: time only the resident backend transcription call;
- `run-file`: separately time native WAV decode plus transcription;
- `shutdown`: flush a response and terminate normally.

Always pass the runner the exact adapter binary, source commit, patch, model
path, and independently expected model hash. The runner hashes all of them and
refuses resume if any experiment identity changes.
