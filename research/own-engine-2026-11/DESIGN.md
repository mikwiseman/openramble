# Own engine design note, November 2026

Mik asked on 22 November 2026 for OpenRamble's own speech recognition library,
written for our Parakeet models, that is much faster than transcribe.cpp on
slow computers and no slower on fast ones. The note covers what was measured,
what was built and why, and the numbers. `LEDGER.md` has every experiment
behind it, and the code is in `engine/`.

## What the measurements say

**The time is in the matrix products.** On the CPU the encoder is 98.5% of a
run. Inside the encoder, 68% of the time is one routine, ggml's 4-bit dot
product, and another 13% is the two other kinds of matrix product. Building
the graph and allocating memory cost nothing visible (ledger M1). So the
language does not matter, and a faster engine has to multiply faster.

**A general tensor library multiplies in the wrong shape for this model.**
ggml multiplies one weight row by one frame at a time. The Parakeet encoder
always multiplies a weight matrix by every frame of the clip. A kernel that
puts 16 frames in the lanes of a register does the same integer arithmetic
and gives the same bits. On the M4 Pro it does 113 to 134 billion
multiply-adds a second where ggml's routine does 60 (ledger K1 and K2).

**The shipped builds leave speed unused.** Windows and Linux give
recognition one thread, because four threads lost to one under load in
October. They also ship the larger 8-bit model file, because ggml ran the
4-bit file 1.3 times slower on the Mac's processor in October. On the hosted
x86 machines ggml runs the 8-bit file 1.1 to 1.3 times slower than the 4-bit
file (ledger S2). The Intel Mac build has AVX2 switched off (ledger M2).

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

**The language is C.** The speed comes from a few hundred lines of processor
instructions, which read the same in C and in Rust, so the choice rests on
other things. Both of our consumers compile C sources directly. Swift Package
Manager builds them as a module, and Rust's `cc` crate builds them on the
Mac in five seconds. On the hosted machines the engine builds in 2 to 12
seconds, where transcribe.cpp takes 1 to 4 minutes. The code this engine has
to agree with is C and C++, so a difference can be traced line against line.
Any other language can call a C library. Rust would have given memory safety
in the file reader, which is 400 lines here and checks every read against
the end of the file.

**The weights are our GGUF files, unchanged and memory-mapped.** There is no
conversion step and no second model file. The 4-bit weights are read from
the mapped file as the kernels go, without unpacking them first. Only the
decoder's weights are expanded to single precision, because the decoder
works on one vector at a time (71 MB).

**The arithmetic is ggml's, kept exactly where it decides the answer.**
Weights are multiplied as the 4-bit and 8-bit integers they are stored as.
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

**No accelerator path was built.** On Apple silicon the Metal runtime the
Mac app ships is faster than this engine, and it stays. The engine is for
the computers that have no such path today, which are Windows and Linux
computers and Intel Macs.

## Reference machines and targets

A slow computer is defined here by three machines that anyone can measure on
for free, because `engine-bench.yml` runs both runtimes on them.

| Reference machine | Stands for |
|---|---|
| GitHub's Windows machine, 2 cores and 4 threads | a Windows laptop with no usable graphics path |
| GitHub's Intel Mac, an i7-8700B from 2018 | the Intel Macs macOS 14 still supports |
| GitHub's Linux arm64 machine, 4 Neoverse-N2 cores | the Arm server `apps/cli` targets, and Windows on Arm |

The hosted machines are servers, and their cores are faster than an old
laptop's. No old laptop was measured, so an old laptop takes longer than the
times below by an amount that is not known. No machine without AVX2 can be
measured from here, so the `sse` kernels are timed on the same hosted
processors with AVX2 switched off in software.

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
are found exactly as often as with the fork. On the English test half both
runtimes find 32 of 37, up from 23 without the list (ledger P2).

**Speed against what ships today.** Windows and Linux ship transcribe.cpp
with the 8-bit model file on one thread. Intel Macs ship it with the 4-bit
file on four threads. The table gives wall time in milliseconds for an 8 s
clip, with the engine reading the 4-bit file (ledger S1 and S2).

| Machine | What ships today | Engine, 1 thread | Engine, 2 threads | Engine, 4 threads |
|---|---|---|---|---|
| Windows, Xeon 8573C | 3,258 | 1,303 | 703 | 960 |
| Windows, EPYC 9V74 | 2,066 | 1,246 | 658 | 600 |
| Linux x86-64, EPYC 7763 | 2,200 | 1,424 | 769 | 717 |
| Linux arm64, Neoverse-N2 | 4,922 | 1,862 | 989 | 530 |
| Intel Mac, i7-8700B, which ships four threads | 1,935 | 2,435 | 1,008 | 892 |

On Windows and Linux the engine on two threads is 2.9 to 5.0 times faster
than what ships, and on four threads 3.1 to 9.3 times. The hosted x86
machines have two cores, so four threads add little there, and on the Xeon
they were slower than two. On the Intel Mac the engine on four threads is
1.9 to 2.9 times faster than what ships, over three runs on a shared machine
whose times differ by up to 40% between runs.

**How much of that is threads.** Part of the gain on Windows and Linux is
the engine using threads that the app does not give transcribe.cpp. At the
same number of threads, and with transcribe.cpp on the file it ships, the
engine is 1.5 to 1.7 times faster on the two AMD processors and 2.5 times
faster on the Intel Xeon and on Linux arm64. The engine's thread pool is
built so that a busy machine does not make four threads slower than one,
which three rounds on the Mac confirm (ledger T1).

**Against the targets.** A 9.3 s take in under a second on two threads is
met on every Windows and Linux x86 machine of the last run (0.76 to 0.89 s).
It is missed on Linux arm64 (1.15 s on two threads, 0.6 s on four) and on
the Intel Mac (1.1 to 1.5 s on two threads, 0.8 to 1.2 s on four). Twice
transcribe.cpp's speed at equal threads is met on Linux arm64 and, on one
and two threads, on the Intel Xeon. On the Intel Mac it holds for the 8 s
clip in all three runs. It is not met on the AMD processors, where the
engine is 1.5 to 1.7 times faster.

**Which model file.** The engine runs both files and gives the same text as
transcribe.cpp with each. It is 10 to 20% faster with the 4-bit file on x86,
and that file is 254 MB smaller. So Windows and Linux would move to the file
the Mac already ships (ledger S2).

**Processors with AVX-512.** One configuration was faster than the
engine's first x86 kernels, which was transcribe.cpp compiled for the exact
processor of a server with AVX-512. The `avx512` kernel set was written for
that case. On an EPYC 9V45 it brings the engine level with such a build, at
623 ms against 613 ms on one thread and 313 against 355 ms on four. On an
older EPYC 9V74 the engine is 9% slower than such a build on one thread for
an 8 s clip (1,102 against 1,009 ms) and 3% faster on four threads (517
against 533 ms) (ledger K7). No package OpenRamble could publish is built
that way, because it would not start on other processors. On Windows on that
older AMD processor the `avx512` set was 10% slower than the `avx2` set. The
engine now gives that processor generation the AVX2 float kernel with the
AVX-512 integer kernels. It picks that table on Linux, and the gain under
Windows has not been measured yet.

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

A change to the shipped runtime and its settings gets part of the gain. The
parts are:

- **The model file.** Giving Windows and Linux the 4-bit file is a change to
  one manifest. transcribe.cpp runs it 1.1 to 1.3 times faster than the 8-bit
  file on x86 and 5% slower on Linux arm64 (ledger S2).
- **Threads.** transcribe.cpp with four threads is 1.9 to 2.5 times faster
  than with one on Windows and the Intel Mac, and 3.9 times on Linux arm64.
  October's test found four threads 1.9 times slower than one when the
  machine is busy, which is why they are off. In three rounds here that
  happened once (ledger T1). Making threads safe means changing ggml's
  thread pool.
- **The Intel Mac build.** Building the Intel slice with AVX2 is one flag and
  gave 1.3 to 2.0 times in three runs on a shared machine (ledger S1).
- **The Windows and Linux builds.** A fixed instruction set (`GGML_NATIVE=OFF`
  with AVX2) is one flag and makes the packages run everywhere AVX2 exists.
  It does not make them faster.

The first two together, against the engine, for an 8 s clip in milliseconds
(ledger S2):

| Machine | What ships today | transcribe.cpp, 4-bit file, four threads | Engine, four threads |
|---|---|---|---|
| Windows, Xeon 8573C | 3,258 | 1,278, 2.5 times | 960, 3.4 times |
| Windows, EPYC 9V74 | 2,066 | 909, 2.3 times | 600, 3.4 times |
| Linux x86-64, EPYC 7763 | 2,200 | 986, 2.2 times | 717, 3.1 times |
| Linux arm64, Neoverse-N2 | 4,922 | 1,375, 3.6 times | 530, 9.3 times |

On the two-core x86 machines the smaller change reaches 2.2 to 2.5 times
where the engine reaches 3.1 to 3.4 times. On Linux arm64 it reaches 3.6
times where the engine reaches 9.3. The smaller change depends on four
threads being made safe in ggml. It does not change the 4-bit product, which
is where the engine's gain per thread comes from. It does not reach a
processor without AVX2, and it still copies the model into memory (479 MB at
peak where the engine uses 118 MB).

## Order of work

1. The kernels are done. They are bit-identical to ggml's and across
   instruction sets.
2. The whole recognizer is done. Its word error rate on FLEURS equals the
   shipped runtime's, with taught words and long audio included.
3. The builds are done. CMake builds and runs the engine on macOS arm64 and
   x86-64, Windows and Linux, with a self-test. Swift Package Manager builds
   it for both Mac architectures, and Rust's `cc` crate builds it on the Mac.
4. The next measurements are four threads against one on a busy Windows or
   Linux machine, and the new kernel choice on Windows on the older AMD
   processor. The test that kept threads off in October passes on the
   Mac.
5. The next step after them needs Mik's yes. It puts the engine behind
   `ramble-engine` for Windows and Linux and behind the Swift adapter for
   Intel Macs, with the real-model test suites as the gate, and it moves
   Windows and Linux to the 4-bit file.
6. Later items each need their own measurement. They are 4-bit weights for
   the two 1x1 convolutions, kernels for Arm's 8-bit matrix extension, a
   cache of the position projections, and recognizing closed stretches of a
   long take while the person is still speaking.
