# Own engine design note, November 2026

Mik asked on 22 November 2026 for OpenRamble's own speech recognition library,
written for our Parakeet models, that is much faster than transcribe.cpp on
slow computers and no slower on fast ones. This note says what was measured,
what was built and why, and what the numbers are. `LEDGER.md` has every
experiment behind it, and the code is in `engine/`.

## What the measurements say

**The time is in the matrix products.** On the CPU the encoder is 98.5% of a
run. Inside the encoder, 68% of the time is one routine, ggml's 4-bit dot
product, and another 13% is the two other kinds of matrix product. Building
the graph and allocating memory cost nothing visible (ledger M1). So the
language does not matter, and a faster engine has to multiply faster.

**A general tensor library multiplies in the wrong shape for this model.**
ggml multiplies one weight row by one frame at a time. The Parakeet encoder
always multiplies a weight matrix by every frame of the clip. A kernel that
puts 16 frames in the lanes of a register does the same integer arithmetic,
gives the same bits, and is 2.4 to 4.8 times faster than transcribe.cpp's
effective rate on four of the five machines measured (ledger K2).

**The shipped builds leave speed unused.** Windows and Linux give
recognition one thread, because four threads lost to one under load in
October. They also ship the larger 8-bit model file, because ggml runs the
4-bit file 1.3 times slower on a processor. The Intel Mac build has AVX2
switched off (ledger M2).

**The published Linux package cannot run on most computers.** It contains
86,539 instructions that need AVX-512, because the runtime is compiled for
the build machine's own processor (ledger M3). The remedy for the current
runtime is one build flag. It is reported separately because it is a release
problem that exists whether or not the engine is adopted.

## What was built

`engine/` holds a recognizer in about 7,300 lines of C with one header,
`ore.h`. "ore" is a working name. It reads our GGUF files as they are, takes
16 kHz samples, and returns text, words with times, and tokens with a
confidence each. It also takes a list of taught words and an abort callback,
and it cuts audio longer than 30 seconds at pauses the way the model's
reference implementation does. It runs both Parakeet families we ship:
Parakeet Ultra, and the v3 family that the Hebrew model belongs to.

One binary runs on every processor of its architecture. When a session opens,
the engine asks the processor what it has and picks one of five sets of
kernels.

| Kernel set | Processors | Same bits as the others |
|---|---|---|
| `neon` | every arm64 since 2018 (dot products) | yes |
| `avx512` | x86-64 with AVX-512 and VNNI | yes |
| `avx2` | x86-64 since 2013 (AVX2 and FMA) | yes |
| `sse` | x86-64 since 2008 (SSSE3, SSE4.1) | integers yes, floats to rounding |
| `generic` | anything else, in plain C | yes, and it is the definition |

### Decisions

**Language: C.** The speed comes from a few hundred lines of processor
instructions, which read the same in C and in Rust, so the choice rests on
other things. Both of our consumers compile C sources directly: Swift Package
Manager builds them as a module, and Rust's `cc` crate builds them in five
seconds, where the transcribe.cpp build takes most of half an hour on a
hosted machine. The code this engine has to agree with is C and C++, so a
difference can be traced line against line. Any other language can call a C
library. Rust would have given memory safety in the file reader, which is
400 lines here and checks every read against the end of the file.

**Weight format: our GGUF files, unchanged, memory-mapped.** No conversion
step and no second model file. The 4-bit weights are read from the mapped
file as the kernels go, without unpacking them first. Only the decoder's
weights are expanded to single precision, because the decoder works on one
vector at a time (71 MB).

**Arithmetic: ggml's, kept exactly where it decides the answer.** Weights
are multiplied as the 4-bit and 8-bit integers they are stored as.
Activations are rounded to 8 bits the way ggml rounds them. The integer sums
and the order of the float additions are ggml's, so a 4-bit product gives the
same bits as transcribe.cpp on arm64. Attention, normalization and the
convolutions are computed in single precision. transcribe.cpp rounds some of
them to half precision, so the two runtimes agree on words, not on every bit.

**Kept from transcribe.cpp.** The mel recipe, the order of operations of the
encoder, the greedy decoding loop, the tokenizer and the automaton for taught
words are ported from it, with its licence notice in `engine/NOTICE.md`.

**Replaced.** The tensor library, the graph, the allocator and scheduler,
the thread pool, every kernel, the accelerator backends and the 17 other
model architectures are gone. The thread pool is new because ggml's makes
every thread wait at a barrier after every graph node. Here the threads take
chunks of work from a shared counter, and a thread the system has not
scheduled is never waited for. With 14 busy processes on the M4 Pro the
engine's four threads were 1.4 to 2.4 times faster than its one in each of
three rounds (ledger T1).

**Not built: an accelerator path.** On Apple silicon the Metal runtime the
Mac app ships is faster than this engine (see the table below), and it stays.
The engine is for every computer that has no such path today: Windows, Linux
and Intel Macs.

## Reference machines and targets

A slow computer is defined here by three machines that anyone can measure on
for free, because `engine-bench.yml` runs both runtimes on them.

| Reference machine | Stands for |
|---|---|
| GitHub's Windows machine, 2 cores and 4 threads | a Windows laptop with no usable graphics path |
| GitHub's Intel Mac, an i7-8700B from 2018 | the Intel Macs macOS 14 still supports |
| GitHub's Linux arm64 machine, 4 Neoverse-N2 cores | the Arm server `apps/cli` targets, and Windows on Arm |

The hosted machines are servers, and their cores are faster than an old
laptop's. A dual-core laptop from 2017 with AVX2 does roughly 0.6 to 0.8 of
the Windows machine's work per core. No machine without AVX2 can be measured
from here, so the `sse` kernels are timed on the same hosted processors with
AVX2 switched off in software.

The target was a 9.3 s take, which is the median take in Mik's own use, in
under one second after key-up on two threads of each reference machine, and
at least twice transcribe.cpp's speed at equal threads.

## Results

**The same words.** On all 1,422 English and Russian FLEURS test clips the
engine makes 1,472 word errors in 29,586 words. transcribe.cpp makes 1,473
on its CPU backend and 1,470 on Metal. The engine's text differs from the
CPU backend's on 130 clips, and transcribe.cpp's own Metal backend differs
from it on 129, so the engine is as close to the shipped runtime as the
shipped runtime's two backends are to each other (ledger P1). Taught words
are found exactly as often as with the fork: 32 of 37 on the English test
half, up from 23 without them, in both runtimes (ledger P2).

**Speed on the reference machines.** Wall time in milliseconds for an 8 s
clip, from the hosted runs (ledger S1). GitHub gave two different Windows
processors, and both are shown.

| Machine | transcribe.cpp, shipped build, 1 thread | engine, 1 thread | engine, 2 threads | engine, 4 threads |
|---|---|---|---|---|
| Windows, Xeon 8573C | 3,396 | 1,622 | 871 | 830 |
| Windows, EPYC 7763 | 2,088 | 1,353 | 734 | 688 |
| Intel Mac, i7-8700B | 3,836 | 1,704 | 1,068 | 707 |
| Linux arm64, 4 cores | 5,376 | 1,953 | 1,001 | 545 |

At equal threads the engine is 2.6 to 2.8 times faster on Linux arm64, 2.3
to 2.9 times on the Intel Mac as shipped, and 1.5 to 2.1 times on Windows,
depending on the processor. Against the one thread the app gives recognition
on Windows and Linux, the engine on four threads is 3.0 to 4.1 times faster
on Windows and 9.9 times on Linux arm64.

**A limit of that table.** Both runtimes read the 4-bit model file. Windows
and Linux users have the 8-bit file today, which transcribe.cpp ran 1.3
times faster on the Mac's processor in October. The comparison against that
file on the hosted machines is not in this note yet (ledger S1, "The model
file"). The Intel Mac row is not affected, because Intel Macs ship the 4-bit
file.

**Against the targets.** Twice transcribe.cpp's speed at equal threads is
met on Linux arm64, on the Intel Mac as shipped, and on one of the two
Windows processors. A 9.3 s take in under a second on two threads is met on
the Windows EPYC 7763 (0.85 s) and missed on the Xeon (1.0 s), the Intel Mac
(1.2 to 1.5 s) and Linux arm64 (1.2 s). On four threads every one of them is
under a second (0.6 to 1.0 s).

**Where the gain is smaller.** A transcribe.cpp built with a fixed AVX2
instruction set, which is the build OpenRamble could ship safely, is 1.3 to
1.6 times slower than the engine on x86, not 2 times. One configuration was
faster than the engine: transcribe.cpp compiled for the exact processor of a
server with AVX-512. The `avx512` kernel set was written for that case. On
an EPYC 9V45 it brings the engine level with such a build: 623 ms against
613 ms on one thread, and 313 against 355 ms on four. On an older EPYC 9V74
the engine is probably still about 9% behind such a build, from two different runs
(ledger K7). No package OpenRamble could publish is built that way, because
it would not start on other processors.

**Fast machines.** On the M4 Pro an 8 s clip takes the engine 203 ms on four
threads and 133 ms on eight. Metal takes 80 ms. The engine is not as fast as
Metal, so the Mac app on Apple silicon keeps the runtime it has. On the M1,
with the processor alone, the engine is 2 times transcribe.cpp's CPU backend.

**Memory, load and size.** An 8 s recognition peaks at 118 MB where
transcribe.cpp's CPU backend peaks at 479 MB, because the model file is
mapped and not copied. The model loads in about 25 ms from a warm file
cache. The static library is 146 KB (ledger R1).

**Any computer.** One binary picks its instructions when it starts, so it
runs on every 64-bit x86 processor since 2008 and every arm64 processor. The
library needs nothing from the system but memory, math, one mapped file, a
clock and threads, which a script checks on the built file (ledger A1). Its
output is the same, to the last digit of every confidence, on macOS,
Windows and Linux and on arm64 and x86-64 (ledger X1).

## The smaller change, and what it gets

A patch to our fork could get part of the gain, and the numbers are these.

- **Threads.** transcribe.cpp with four threads is 3.3 times faster than with
  one on the Intel Mac and 3.9 times on the Linux arm64 machine. October's
  test found it 1.9 times slower than one thread when the machine is busy,
  which is why it is off. Making it safe means changing ggml's thread pool.
- **The Intel Mac build.** Building the Intel slice with AVX2 is one flag and
  gives 1.5 times (472 to 321 ms per second of audio, ledger K2).
- **The Windows and Linux builds.** A fixed instruction set (`GGML_NATIVE=OFF`
  with AVX2) is one flag and makes the packages run everywhere AVX2 exists.
  It does not make them faster.

None of these changes the 4-bit product, which is where the engine's gain
per thread comes from, and none of them reaches a processor without AVX2.

## Order of work

1. Done: kernels, bit-identical to ggml's and across instruction sets.
2. Done: the whole recognizer, word error rate on FLEURS equal to the
   shipped runtime's, taught words and long audio included.
3. Done: builds and runs on macOS arm64 and x86-64, Windows and Linux from
   CMake, with a self-test. Swift Package Manager builds it for both Mac
   architectures, and Rust's `cc` crate builds it on the Mac.
4. Next: the comparison with the 8-bit file that Windows and Linux ship,
   and four threads against one on a busy Windows or Linux machine. The test
   that kept threads off in October passes on the Mac.
5. Then, with Mik's yes: put the engine behind `ramble-engine` for Windows
   and Linux and behind the Swift adapter for Intel Macs, with the real-model
   test suites as the gate.
6. Later, each behind its own measurement: 4-bit weights for the two 1x1
   convolutions, kernels for Arm's 8-bit matrix extension, a cache of the
   position projections, and recognizing closed stretches of a long take
   while the person is still speaking.
