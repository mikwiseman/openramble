# Speech runtime spike: results and recommendation

Measured on 27 October 2026 on an Apple M4 Pro with 24 GB, macOS 27.0.1.
`candidates.md` describes each runtime, how it was installed, and the effort
estimate for a Parakeet-only engine. `measure.py` made every number below,
and `data/` holds its inputs, every transcript and every timing.

## Recommendation

Keep transcribe.cpp as OpenRamble's only runtime, built from our fork. Do not
rewrite the engine, and do not move to another runtime.

- transcribe.cpp was the only runtime that lost no words on either set. It
  had the lowest pooled WER on both sets, the smallest model (486 MB) and,
  among runtimes whose memory can be measured, the least memory (about
  300 MB), and it runs on the Mac, Linux and Windows from one source.
- FluidAudio on the Neural Engine is about twice as fast, but it lost 13
  words on the long clips, because its encoder sees 15 s windows. Its Russian
  was worse on short clips, it works only on Apple platforms, and its first
  load of the evening took 9.9 s because Core ML compiled the model again,
  although it had been compiled at 18:16. If speed is ever needed, the
  cheaper way to get it is H12 (only the encoder on the Neural Engine, with
  Metal as the fallback), not a new runtime. Metal already transcribes a
  28 s clip in 0.29 s.
- parakeet-mlx is Mac-only and Python-only, its Russian is worse, and it
  turned one long clip into nonsense on weights that are exactly Ultra's.
- sherpa-onnx is the one other runtime for all three platforms, and on the
  CPU it is 2.1 times faster than transcribe.cpp with the same four threads.
  Its Ultra is a third-party int8 export that is 2.3 points worse and lost 30
  words. It is worth a second look only if the Windows and Linux CPU speed
  becomes the problem, and then with an export we make and judge ourselves.
- A lean engine is not worth building now. A Parakeet-only fork that deletes
  the other 17 architectures and the unused backends takes an estimated 2 to
  4 weeks and would make a 9.0 MB binary smaller, but no faster or more
  accurate. A new C engine without ggml takes an estimated 9 to 14 weeks for
  the CPU alone and 14 to 22 with Metal, and would likely be slower on the
  CPU. Keeping the fork as upstream's releases plus our few fixes costs about
  a day per upstream release.

## What was measured

Every runtime ran Parakeet Ultra in its own format:

| Runtime | Version | Model | Where it runs here | Threads |
|---|---|---|---|---:|
| transcribe.cpp | fork `c4cd60da` (0.4.1 and the long-form fix) | handy-computer GGUF, Q4_K_M, 486 MB | Metal, as the Mac app | 1 |
| transcribe.cpp | the same | the same | CPU, as Linux and Windows | 4 |
| sherpa-onnx | 1.13.8 | leogaudin int8 export (third party), 640 MB | CPU | 4 |
| parakeet-mlx | 0.5.3, MLX 0.32.4 | converted here from moondream/parakeet-ultra, float16, 1.18 GB | GPU | – |
| FluidAudio | 0.17.7 | FluidInference Core ML, int8 encoder, 605 MB | Neural Engine | – |

So accuracy differences mix the runtime with the conversion. Only the MLX
weights are exactly Ultra's own; the others are quantized.

Two sets, each led by a warm-up file that is left out of every number:

- **fleurs200**: the scorecard's frozen 100 English and 100 Russian FLEURS
  test utterances (34.3 minutes).
- **long30**: 15 English and 15 Russian clips of 25.5 to 29.4 s (13.5
  minutes), each a run of whole FLEURS utterances not in fleurs200, joined by
  0.5 s of silence. OpenRamble gives the engine at most 30 s at a time, so
  this is the longest input any runtime would get from the app.

Each runtime ran as its own process under `/usr/bin/time -l`, one at a time,
twice: once in the order of the tables and once reversed. A run started only
when the Mac was at least 75% idle (the scorecard's rule), and every run saw
82 to 88% idle. Every runtime gave the same text in both rounds for every
file, so accuracy comes from one round and speed from both.

## Accuracy

WER in percent, scored like the scorecard (its normalization, jiwer 4.0.0).
Lost words are reference words in deleted runs of three or more.

| Runtime | fleurs200 EN | fleurs200 RU | long30 EN | long30 RU | Lost words, fleurs200 / long30 |
|---|---:|---:|---:|---:|---:|
| transcribe.cpp, Metal | 5.47 | 5.53 | 5.53 | 5.11 | 0 / 0 |
| transcribe.cpp, CPU | 5.57 | 5.42 | 5.87 | 4.96 | 0 / 0 |
| sherpa-onnx, CPU | 7.72 | 7.86 | 10.38 | 6.72 | 11 / 19 |
| parakeet-mlx, GPU | 5.47 | 6.75 | 9.48 | 5.11 | 0 / 3 |
| FluidAudio, Neural Engine | 5.19 | 6.32 | 7.56 | 4.82 | 0 / 13 |

- FluidAudio lost a 9-word run in `long30-en-12`, at a seam between its 15 s
  windows.
- parakeet-mlx turned `long30-en-04` into nonsense ("loyal bottom regularly
  is a lot" for "boiling water for a minute is enough"; WER 34%). That clip
  holds the quiet FLEURS utterances of upstream issue #235, about 40 dB below
  their neighbour. transcribe.cpp and FluidAudio got it right.
- sherpa-onnx lost 19 words in a row in `long30-en-09` and was worse on every
  set.

## Speed

Wall time per file for audio already in memory (features, encoder and
decoding), the median and 95th percentile over both rounds. The real-time
factor is the median of wall time over audio length.

| Runtime | fleurs200 median / p95, s | long30 median / p95, s | Real-time factor, fleurs200 / long30 |
|---|---:|---:|---:|
| transcribe.cpp, Metal | 0.112 / 0.193 | 0.290 / 0.317 | 0.012 / 0.011 |
| transcribe.cpp, CPU | 0.470 / 0.816 | 1.347 / 1.482 | 0.048 / 0.050 |
| sherpa-onnx, CPU | 0.225 / 0.377 | 0.615 / 0.687 | 0.023 / 0.023 |
| parakeet-mlx, GPU | 0.150 / 0.446 | 0.323 / 0.450 | 0.015 / 0.012 |
| FluidAudio, Neural Engine | 0.056 / 0.113 | 0.131 / 0.263 | 0.006 / 0.005 |

## Load, memory and size

| Runtime | Model load, s | Peak footprint | Max resident | Model on disk | Runtime binary |
|---|---|---:|---:|---:|---|
| transcribe.cpp, Metal | 3.44 on the first run after the runner was built (Metal compiles its kernels), then 0.06 | 282 to 305 MB | 258 to 282 MB | 486 MB | CTranscribe, 9.0 MB arm64 (4.5 MB x86_64), shaders inside |
| transcribe.cpp, CPU | 0.10 to 0.23 | 581 to 653 MB | 1.03 to 1.12 GB | 486 MB | the same |
| sherpa-onnx, CPU | 0.76 to 1.03 | 1.9 to 2.5 GB | 1.7 to 2.5 GB | 640 MB | 4.2 MB C API and 29.0 MB ONNX Runtime |
| parakeet-mlx, GPU | 0.39 to 0.69 | 14 to 17.5 GB | 1.1 to 1.4 GB | 1.18 GB | 21.7 MB libmlx and a 214 MB Metal library, plus Python |
| FluidAudio, Neural Engine | 9.95 on the first run of the evening (Core ML compiled again), then 0.09 to 0.11 | 76 to 89 MB | 0.13 to 0.65 GB | 605 MB | 10 MB runner with FluidAudio inside |

- The Neural Engine's memory is not counted in the process, so FluidAudio's
  figures leave out the model.
- MLX keeps freed GPU buffers in a cache that the footprint counts. A cache
  limit would lower it; that was not tested.
- FluidAudio's compile cache, `~/Library/Caches/fluidaudio-runner`, held
  1.2 GB after the smoke tests at 18:16 and 36 MB after these runs, and
  nothing of ours deleted it. The first load of round 1 took 9.95 s, as a
  compile does, and every later load 0.09 to 0.11 s. Where Core ML keeps the
  recompiled model was not found. Loads that compile again unexpectedly are
  what cost the app 16 s in August 2026.

## Platforms

| Runtime | macOS Apple silicon | Intel Mac | Linux | Windows | Swift | Rust |
|---|---|---|---|---|---|---|
| transcribe.cpp | Metal | CPU | CPU (Vulkan possible) | CPU (Vulkan possible) | today | today |
| sherpa-onnx | CPU (Core ML provider slower) | CPU | CPU, CUDA | CPU, CUDA | C API | official crates |
| parakeet-mlx | GPU | no | not tested by the project | no | needs a port to mlx-swift | no |
| FluidAudio | Neural Engine | Core ML on CPU or GPU, not tried | no | no | SwiftPM | no |

## Reproducing

```bash
R=research/runtime-spike-2026-10
uv run --with jiwer==4.0.0 python -I $R/measure.py prepare
uv run --with jiwer==4.0.0 python -I $R/measure.py run r1
uv run --with jiwer==4.0.0 python -I $R/measure.py run r2 fluidaudio-ane mlx-gpu sherpa-cpu tcpp-cpu tcpp-metal
uv run --with jiwer==4.0.0 python -I $R/measure.py report
```

The transcribe.cpp runner is `runners/transcribe-cpp/runner.c`, linked to the
fork's framework:

```bash
F=~/Library/Caches/OpenRambleSpike/transcribe-cpp/TranscribeCpp.xcframework/macos-arm64_x86_64
xcrun clang -O2 -I$F/CTranscribe.framework/Versions/A/Headers $R/runners/transcribe-cpp/runner.c \
  -F$F -framework CTranscribe -Wl,-rpath,$F -o ~/Library/Caches/OpenRambleSpike/transcribe-cpp/runner
```
