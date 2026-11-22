# ore, OpenRamble's recognition engine

`ore` turns 16 kHz speech into text with NVIDIA's Parakeet TDT models. It reads
the GGUF model files OpenRamble already ships, runs on the processor alone, and
is written in plain C with no dependencies. It was written for one model
family, so it does not contain a tensor library, a graph, or any other model.

The name is a working name ("OpenRamble engine") and can change.

## What it runs

- Parakeet Ultra (`parakeet-ultra-Q4_K_M.gguf`, and the Q8_0 file).
- Parakeet TDT 0.6B v3 and its fine-tunes, e.g., the Hebrew model.

A model file of any other kind is refused when it is opened, with a message
that says why.

## Using it

```c
#include "ore.h"

ore_model *   model   = ore_model_open("parakeet-ultra-Q4_K_M.gguf", NULL);
ore_session * session = ore_session_open(model, 0);   // 0 threads = a default

if (ore_run(session, samples, n_samples) == ORE_OK) {
    puts(ore_text(session));
}

ore_session_close(session);
ore_model_close(model);
```

`include/ore.h` is the whole interface. It also gives the words with their
start and end times, the tokens with a confidence each, a list of words to
favour, and a callback that stops a recognition part-way.

## Building it

The sources in `src/` compile as they are. There is nothing to configure.

- **CMake**, for the static library and the tools:
  `cmake -S engine -B build && cmake --build build`
- **Swift**: `Package.swift` in this folder makes the sources a module named
  `ORE`.
- **Rust**: compile `src/*.c` with the `cc` crate. On MSVC, give
  `ore_kernels_avx2.c` the flag `/arch:AVX2`; every other compiler reads the
  instruction set from the source.

One binary runs on every processor of its architecture. When a session opens,
the engine asks the processor what it has and picks a set of kernels.

| Kernel set | Processors |
|---|---|
| `neon` | arm64 with dot products: every Apple silicon Mac, Arm servers and Windows on Arm since 2018 |
| `avx512` | x86-64 with AVX-512 and VNNI: AMD from Zen 4, Intel from Ice Lake where present |
| `avx2` | x86-64 with AVX2 and FMA: Intel from 2013, AMD from 2015 |
| `sse` | x86-64 with SSSE3 and SSE4.1: Intel from 2008, AMD from 2011 |
| `generic` | anything else, in plain C |

`neon`, `avx512`, `avx2` and `generic` give the same bits, and the hosted
machines confirm it: the same clips give byte-identical text, token times and
confidences on Linux, Windows and macOS, on x86 and Arm. `sse` runs on
processors without fused multiply-add, so its results can differ in the last
bits; it gives the same text on the clips tested.

## Tools

- `ore-cli run MODEL CLIP.wav` prints the transcript.
- `ore-cli time MODEL CLIP.wav THREADS` prints times by clip length.
- `ore-cli dump MODEL LIST.txt` prints text, tokens and confidences for many
  clips, in the form `research/own-engine-2026-11/tools/parity.py` compares.
- `kbench MODEL` times each kernel on real weights and checks that every set
  of kernels agrees with the plain C one.
- `tcpp-probe` is the same as `ore-cli` for transcribe.cpp, for comparisons.
  It is built only when CMake is given `-DORE_TCPP_PREFIX=`.
- `selftest` checks every part that needs no model file: each kernel set
  against the plain C one, the conversions, the thread pool, the file reader
  and the mel front end. `ctest` runs it.
- `scripts/check-symbols.sh libore.a` fails if the built library needs
  anything from the system beyond memory, math, one mapped file, a clock and
  threads.

## Long audio

Parakeet Ultra recognizes at most 30 seconds at a time. A longer clip is cut
at pauses, found with the small speech detector the model file carries, and
each piece is recognized on its own. The rule is the model's own, ported from
transcribe.cpp, and the cuts fall on the same samples. A model without that
detector (the v3 family) takes clips of at most two minutes.

## What it does not do

- It has no accelerator path. On Apple silicon the Metal runtime the Mac app
  uses is faster.
- It does not stream partial results.

The measurements, the design and what is unfinished are in
`research/own-engine-2026-11/`. `NOTICE.md` lists the MIT-licensed code the
engine follows.
