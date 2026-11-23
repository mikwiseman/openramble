# Own engine ledger, November 2026

Mik's request on 22 November 2026 was to write OpenRamble's own recognition
library, so that recognition is much faster on slow computers. Each entry
below records what was measured, the hypothesis, the result and the decision.
Negative results stay. `DESIGN.md` in this folder is the design that follows
from them.

Raw outputs are outside the repository in `~/.openramble/own-engine/`. The
hosted-machine numbers come from the workflow `engine-bench.yml`, whose logs
GitHub keeps for 90 days. The run numbers are given with each table.

"Multiply-adds per second" is the unit used for kernels. One second of audio
costs the Parakeet encoder about 7.9 billion multiply-adds: 629 million per
encoder frame, and 12.5 frames per second.

## M1. Where a CPU run's time goes

Method. transcribe.cpp at the shipped commit (`dacdba09`), built for arm64
with the CPU backend, Parakeet Ultra Q4_K_M, one thread, an 8 s clip in a
loop on the M4 Pro, sampled for ten seconds with `sample`.

Result. The encoder is 98.5% of a run, and inside it the time is in the
matrix products, not around them.

| Where | Share of the samples |
|---|---|
| `ggml_vec_dot_q4_K_q8_K`, the 4-bit dot product | 68% |
| float matrix product (the two 1x1 convolutions) | 11% |
| quantizing activations to 8 bits (`quantize_row_q8_K_ref`) | 3% |
| 8-bit matrix product (attention output) | 2% |
| everything else, each under 2.5% | 16% |

Graph building and memory allocation do not appear. A run takes 160 ms per
second of audio with one thread, 85 ms with two and 44 ms with four.

Reading. ggml multiplies one weight row by one frame per call. For every such
pair it unpacks the same 4-bit weights again, and its arm64 routine adds each
group of 32 products across a register before applying the group's scale.

Decision. A faster engine has to be a faster matrix product first. The
language alone changes nothing, because transcribe.cpp is already C++ on C.

## M2. How the shipped builds are configured

Read from `core/ramble-engine/Cargo.toml`, the fork's Rust build script and
`desktop-release.yml`, and confirmed on the hosted machines.

- Windows and Linux give recognition one thread (`ramble-engine`), because
  four threads lost to one under load in October (H10 in the model-upgrade
  ledger). The Intel Mac gives it four threads, in the Swift adapter and in
  `ramble-engine`.
- Windows and Linux ship the Q8_0 model (740 MB), because ggml ran the Q4_K_M
  file (486 MB) 1.29 times slower on the CPU (H13). That was measured on the
  M4 Pro. S2 measures it on the hosted machines and finds the opposite on
  x86.
- The Intel slice of the Mac framework is built for a 2019 instruction floor
  with AVX2 and FMA switched off. Every Intel Mac that macOS 14 supports has
  both.
- On Windows and Linux the build leaves ggml's `GGML_NATIVE` at its default,
  so the runtime is compiled for whatever processor the build machine has.
  See M3.

## M3. The published Linux package needs AVX-512

Hypothesis. If the release machine had AVX-512, the published package uses
it, and stops with an illegal instruction on a computer without it.

Method. The hosted job "Published packages, instruction sets" downloads the
0.37.0 packages from the repository's release, disassembles the main
executable and counts instructions by the registers they name (run
45033169110).

| Package | Instructions | On AVX-512 registers | On mask registers | On 256-bit registers | Fused multiply-adds |
|---|---|---|---|---|---|
| Linux `.deb`, `openramble-desktop` | 3,468,090 | 86,539 | 3,407 | 46,405 | 1,898 |
| Windows setup, `openramble-desktop.exe` | 3,157,114 | 0 | 466 | 21,377 | 904 |

The same workflow shows the cause on a Windows runner, where ggml's configure
step printed `Adding CPU backend variant ggml-cpu: /arch:AVX512 GGML_AVX512`.

Result. The Linux package contains 86,539 instructions that only run on a
processor with AVX-512. Intel removed AVX-512 from its consumer processors
in 2021 and AMD added it in 2022, so most computers cannot run them. The
Windows package needs AVX2 and FMA, which processors from 2013 on have. It
also has 466 instructions on AVX-512 mask registers, and I have not checked
whether recognition reaches them.

Decision. Not fixed here, because it changes a shipping build. It is reported
to Mik as a release problem with a one-line remedy for the current runtime
(build with `GGML_NATIVE=OFF` and a fixed instruction set). The engine removes
the cause, because it chooses its instructions when it starts.

## K1. A 4-bit product that keeps ggml's arithmetic (first version)

Hypothesis. Unpacking a weight row once and using it for several frames,
with the same integer sums and the same float order as ggml, gives the same
bits several times faster.

Method. `engine/tools/kbench.c` runs real weight matrices of block 0 against
100 frames of pseudo-random activations. On the Mac it also calls ggml's own
routines from the fork's static library, for speed and for a bit-for-bit
comparison.

Result on the M4 Pro, one thread, billions of multiply-adds per second:

| Kernel | ggml | First version |
|---|---|---|
| Q4_K, 1024 to 4096 | 60 | 114 |

All 409,600 outputs are bit-identical to ggml's, and the plain C, NEON and
AVX2 versions are bit-identical to each other.

On GitHub's Intel machines the gain was smaller (run 45015846565). The AVX2
version reached 65 billion per second on a Xeon 6975P, where transcribe.cpp
as a whole already works at an effective 71. It spent one multiply per frame
on each group's scale and ended every block with horizontal sums.

Decision. Keep the arithmetic, change the layout. See K2.

## K2. Frames in the vector lanes

Hypothesis. The encoder always multiplies a weight matrix by every frame of
the clip. If the activations are stored 16 frames at a time, four columns
interleaved, one instruction multiplies four weights by 8 or 16 frames and
each lane holds one frame's sum. On AVX2 the 16-bit sums of a whole group of
32 columns then fit in 16 bits (8 x 2 x 15 x 127 is below 32,768), so a group
needs one 8-bit multiply per four columns and a single widening multiply at
its end, which also applies the scale.

Result, one thread, billions of multiply-adds per second (run 45030438487
and the M4 Pro). The last column is transcribe.cpp's effective rate for the
whole encoder on the same machine, which is 7.9 divided by its seconds per
second of audio.

| Machine | Q4_K kernel | 8-bit kernel | Float kernel | transcribe.cpp, whole encoder |
|---|---|---|---|---|
| M4 Pro | 113 to 134 | 122 to 134 | 43 to 48 | 49 |
| Intel Mac, i7-8700B | 70 to 87 | 42 | 34 to 36 | 16.6 as shipped, 24.5 built with AVX2 |
| Linux arm64, Neoverse-N2 | 42 to 45 | 44 | 15 | 13.3 |
| Windows, Xeon Platinum 8573C | 55 to 58 | 41 | 30 | 19 |
| Linux x86-64, EPYC 9V74 | 74 to 80 | 51 | 42 | 63 |

The outputs are still bit-identical to ggml's arm64 routine and across the
three kernel sets. The table is the state of that run. K4 and K5 changed the
kernels afterwards, and S1 has the final times.

Decision. Adopt. The kernel is 2.4 times transcribe.cpp's effective rate on
the M4 Pro, 3 times on Windows, 3.3 times on Linux arm64, 4.8 times on the
Intel Mac as shipped, and 1.2 times on a new AMD server, where ggml built for
that exact processor is already fast.

## K3. ggml's routine called directly on Linux and Windows (not resolved)

`kbench` calling `ggml_vec_dot_q4_K_q8_K` directly gives all zeros on the
x86 runners and wrong values on Linux arm64, although the same harness is
bit-identical on the Mac. I did not find the reason. The comparison is
therefore reported only for the Mac, and every speed comparison on the
hosted machines uses transcribe.cpp as a whole, through its public
interface, which gives the right words.

## K4. GCC and MSVC kept the accumulators in memory

Hypothesis. The kernel of K2 was fast when Clang built it and slow when GCC
or MSVC did. On GitHub's Linux Xeon the whole engine took 1,272 ms for an 8 s
clip where transcribe.cpp took 950 ms (run 45033442799), although the same
source was 4.8 times transcribe.cpp's rate on an older Intel Mac.

Cause. The loops kept their sums in small arrays of vector registers. Clang
turns such an array into registers. GCC and MSVC keep it in memory, so every
addition went through a store and a load.

Change. The products are written with one named variable per register, and
there is one function per number of frame vectors.

Result. The outputs are unchanged, bit for bit. On the Linux Xeon the 8 s
clip went from 1,272 to 1,146 ms and the 30 s clip from 5,662 to 4,953 ms
(run 45034315337). The gain was smaller than expected, and K5 found the rest.

Decision. Adopt, and keep vector registers out of arrays in every kernel.

## K5. A fixed cost per recognition: unpacking every weight row

Observation (run 45034315337, Windows, AMD EPYC 7763, MSVC, one thread). The
engine's encoder took 864, 1,146, 1,708, 2,891 and 5,202 ms for clips of 2,
4, 8, 16 and 30 s. A straight line through those points is 155 ms per second
of audio plus 554 ms that does not depend on the length.

Cause. Each kernel unpacked a weight row from 4 bits to bytes before using
it. The model has 503 million such weights, so every recognition unpacked
503 million of them whatever its length, in a loop MSVC does not vectorize.

Change (commit `26ae0d9`). The kernels read the 4-bit weights from the
mapped file as they go and mask them in a general register. Block headers
are decoded with three masked 32-bit shifts, which is ggml's method.

Result. On the M4 Pro, the same machine before and after, an 8 s clip went
from 747 to 690 ms on one thread and from 256 to 234 ms on four. On Windows
the next run had a different processor, so there is no like-for-like pair.
On that machine (run 45044832938, EPYC 9V74 with an AVX2 build) an 8 s clip
takes 1,158 ms and a 30 s clip 4,424 ms. The ratio is 3.8, as it should be
when nothing is fixed.

Decision. Adopt.

## K6. Kernels for x86 processors without AVX2

The `sse` set uses SSSE3 and SSE4.1, which Intel has had since 2008 and AMD
since 2011. It is the AVX2 kernel at half the width. Processors of that age
have no fused multiply-add, so a result can differ from the other sets in its last
bits. `kbench` therefore checks this set to a tolerance of one part in ten
thousand, and the others bit for bit. On the sample clips it gives the same
text as the other sets on every x86 machine (run 45044832938).

No processor without AVX2 can be measured from here, so the set was timed on
the hosted processors with the better sets switched off. An 8 s clip on one
thread takes 1.8 to 3.3 s, about twice the AVX2 time on the same machine, and
0.8 to 1.5 s on four threads (S1).

Decision. Adopt. transcribe.cpp as OpenRamble builds it does not start on
these processors.

## K7. Kernels for AVX-512 with VNNI

Observation. One configuration was slower than transcribe.cpp. On an AMD
EPYC 9V74, against transcribe.cpp compiled for that exact processor, which
uses AVX-512, the AVX2 kernels took 1,227 ms for an 8 s clip where
transcribe.cpp took 1,017 ms (run 45044832938). On an Intel Xeon 6975P the
figures were 1,146 and 956 ms (run 45034315337).

Change. A fifth kernel set uses the VNNI instruction that multiplies four
8-bit weights by four columns of sixteen frames and adds into 32-bit sums. It
keeps the same integers and the same order of float additions, so it is held
to the plain C table bit for bit.

Result (run 45046209178, Linux x86-64 on an AMD EPYC 9V45, transcribe.cpp
compiled for that processor). The set gives the plain C table's bits.

| One thread, billions of multiply-adds per second | `avx512` | `avx2` |
|---|---|---|
| Q4_K kernel | 139 to 151 | 105 to 112 |
| 8-bit kernel | 131 | 78 |
| Float kernel | 90 | 62 |

| Whole recognition, ms | engine, `avx512` | engine, `avx2` | transcribe.cpp |
|---|---|---|---|
| 8 s, one thread | 623 | 846 | 613 |
| 30 s, one thread | 2,246 | 3,038 | 2,210 |
| 8 s, four threads | 313 | 400 | 355 |
| 30 s, four threads | 1,195 | 1,573 | 1,158 |

The same run on an EPYC 9V74, an older AMD design. The set gains less
there: the Q4_K kernel does 77 to 90 billion multiply-adds a second where the
`avx2` set does 70 to 74, and an 8 s clip takes 1,107 ms where the `avx2` set
takes 1,227 ms. transcribe.cpp on that machine was the AVX2 build, at
1,636 ms. That run had no transcribe.cpp compiled for the 9V74. Against
the earlier run's 1,017 ms the engine would be about 9% slower on that
processor, and a later run measures it (below).

On Windows the set is not always a gain (run 45047905043, MSVC). On a Xeon
Platinum 8573C an 8 s clip takes 1,303 ms with `avx512` and 1,605 ms with
`avx2`. On an EPYC 9V74 it takes 1,246 ms with `avx512` and 1,126 ms with
`avx2`, so the engine's own choice costs 10% there. The float kernel is the
cause: 33 billion multiply-adds a second with `avx512` against 43 with
`avx2` on that machine, where GCC on the same processor gives 46 and 45. The
4-bit kernels are level there.

Change (commit `3c1b967`). AMD processors of family 19h with AVX-512, which
is the generation of the EPYC 9V74, now get a table named `avx512+avx2`. It
has the AVX-512 integer kernels and the AVX2 float kernel. Intel processors
and the newer AMD generation keep the whole `avx512` set, because the
512-bit float kernel wins there. The choice is made from the processor's
vendor and family, not from a timing.

Result (run 45050213787, first attempt). No job landed on an AMD processor
of that generation. On an Intel Xeon 6975P the new table gives the plain C
table's bits in every comparison, and the float kernel does 60 billion
multiply-adds a second in `avx512` and 50 in `avx512+avx2`, which is why
Intel keeps `avx512`. All seven machines print the common checksum.

Result (the same run, third attempt). The Linux job with transcribe.cpp
compiled for its own processor landed on an EPYC 9V74. The engine chose
`avx512+avx2` there, so the detection works, and the table gives the plain
C table's bits. Under GCC the two AVX-512 tables are equally fast on that
processor (1,102 and 1,099 ms for the 8 s clip), and both are 9% faster than
`avx2` (1,210 ms). The job is also the first with the AVX-512 kernels and a
transcribe.cpp compiled for the 9V74 together:

| EPYC 9V74, ms | engine, `avx512+avx2` | transcribe.cpp for that processor |
|---|---|---|
| 8 s, one thread | 1,102 | 1,009 |
| 8 s, two threads | 580 | 546 |
| 8 s, four threads | 517 | 533 |
| 30 s, one thread | 4,088 | 3,953 |
| 30 s, two threads | 2,102 | 2,074 |
| 30 s, four threads | 1,871 | 1,948 |

The engine is 9% slower than such a build on one thread for the 8 s clip,
3% slower for the 30 s clip, and 3 to 4% faster on four threads.

Still not measured. Both Windows jobs of that attempt landed on an EPYC
7763, which has no AVX-512. So the case the change was made for, MSVC on the
9V74, has no measurement with the new table.

Decision. Adopt. On the EPYC 9V45 the engine is level with a transcribe.cpp
compiled for that exact processor: between 0.89 and 1.16 times its speed over
five clip lengths and three thread counts. The 2 s clip is the slow end
(206 against 184 ms on one thread), because of the fixed cost listed under
"Not done". The engine is not faster there. The share of the time outside
the 4-bit product is what remains, and the float kernel is the largest part
of it.

## K8. The M4's matrix unit against NEON, the 8-bit matrix extension and Accelerate

Question. On Apple silicon the engine loses to the Metal runtime the Mac app
ships (S1: 133 ms on eight threads against 80 ms for an 8 s clip on the M4
Pro). Is there an instruction set on the processor that closes the gap?

Method. `tools/apple_matmul_probe.c` multiplies one encoder matrix, 4096 rows
of 1024 8-bit weights, by 112 frames of 8-bit activations (470 M
multiply-adds) four ways and checks every integer result against a plain
loop. M4 Pro, 23 November 2026, load average 4, best of 5 to 7.

| Way | Time | Multiply-adds a second |
|---|---|---|
| NEON dot products, one thread | 4.14 ms | 114 G |
| 8-bit matrix extension (`smmla`), one thread, packing counted | 4.81 ms | 98 G |
| Matrix unit (SME `smopa`), one thread | 0.26 ms | 1,786 G |
| Matrix unit, two threads | 0.28 ms | 1,696 G |
| Matrix unit, four threads | 0.18 ms | 2,595 G |
| Matrix unit, eight threads | 0.17 ms | 2,780 G |
| Accelerate `cblas_sgemm`, single precision | 0.41 ms | 1,146 G |

Found.

- One thread on the matrix unit does 16 times the work of one NEON thread,
  and twice the work of all eight NEON threads of S1 together.
- The 8-bit matrix extension is no faster than dot products here, so the
  "Not done" item for it is closed for Apple silicon. It may still pay on
  Neoverse-N2 and Snapdragon X, which was not measured.
- More threads add little (1.5 times at four), which fits one matrix unit
  per group of cores.
- The activations the engine already makes (`ore_qact.q`, 16 frames by 4
  columns in 64 bytes) are exactly one operand of `smopa`. The weights are
  not: the instruction wants 16 rows by 4 columns, and the file stores rows.

What it does not show. The probe multiplies plain 8-bit numbers. The Q4_K
arithmetic the engine keeps bit for bit has a 6-bit scale and a minimum for
every 32 columns of every row. Counted on paper, keeping it on the matrix
unit takes two passes of products and about as many side instructions again,
which lands near four NEON threads, not above them. The gain needs weights
stored as 8-bit numbers with one scale for a row. That is a new model file
and changes the numbers, so it has to pass the word-error gate before
anything ships. M1, M2 and M3 have no matrix unit, so this is a path for M4
and later only.

## T1. A thread pool that waits for no one

Background. Windows and Linux ship one thread because ggml's four threads
were 1.9 times slower than one when the machine was busy (October's H10).
ggml makes every thread wait at a barrier after every node of the graph, so
one thread the system has not scheduled stops all of them.

Design. Work is handed out in chunks from a shared counter, and the calling
thread takes chunks too. When the caller has taken the last chunk it closes
the job and waits only for the workers that are inside it. A worker that
wakes up late finds the job closed and does not join. Idle workers spin for
150 microseconds and then sleep on a condition variable. The spin is timed,
because a pause instruction takes 40 ns on x86 and almost nothing on arm64.

Timed spinning and sharing the decoder's products among the threads took
an 8 s clip on four threads of the M4 Pro from 234 to 197 ms, and its
decoding part from 40 to 17 ms. transcribe.cpp decodes that clip in 21 ms
with Accelerate.

Result on idle machines (run 45044832938, 30 s clip, one thread to four).
Linux arm64 with four cores goes from 7,525 to 2,154 ms, which is 3.5 times.
The x86 machines have two cores with two threads each, and go from 4,677 to
2,265 ms (Linux) and from 6,513 to 3,179 ms (Windows), which is 2.1 times.
The address, undefined-behaviour and thread sanitizers report nothing.

Result on a busy machine. October's rule was that with 14 busy processes
the four-thread median must not be slower than the one-thread median. The
test was run three times on the M4 Pro (14 cores) on 22 November, 8 s clip,
median of five. The Mac was never idle to begin with, because other sessions
were working on it.

Round 1, at 18:58, load average 9 as found:

| 8 s clip, median, ms | as found | with 14 more busy processes |
|---|---|---|
| engine, one thread | 724 | 1,483 |
| engine, four threads | 251 | 612 |
| transcribe.cpp CPU, one thread | 2,252 | 2,912 |
| transcribe.cpp CPU, four threads | 2,224 | 3,228 |

Rounds 2 and 3, with the 14 busy processes and a test suite from another
session running:

| 8 s clip, median, ms | round 2 | round 3 |
|---|---|---|
| engine, one thread | about 1,100 to 1,300 | about 1,100 to 1,300 |
| engine, two threads | 991 | 1,316 |
| engine, four threads | 683 | 788 |
| transcribe.cpp CPU, one thread | 2,459 | 4,778 |
| transcribe.cpp CPU, two threads | 2,613 | 2,656 |
| transcribe.cpp CPU, four threads | 1,998 | 1,953 |

In all three rounds the engine's four threads are faster than its one, by
1.4 to 2.4 times. The rule passes for the engine. transcribe.cpp's four
threads were slower than its one in round 1 and faster in rounds 2 and 3, so
October's finding did not reproduce in two rounds of three.

Limits of this test. It is one machine, a Mac that other work was already
loading, and transcribe.cpp's one-thread time varies by 1.9 times between
rounds. It has not been run on Windows or Linux, where the engine would
ship.

## P1. The same words: all 1,422 FLEURS clips

Method. `ore-cli dump` and `tcpp-probe dump` print text, token ids, token
times and confidences for every English and Russian FLEURS test clip, the
set the October and November gates used. `tools/parity.py` compares them and
scores word errors as the polish loop did. Three runtimes were compared on
the M4 Pro with Parakeet Ultra Q4_K_M: the engine, transcribe.cpp on its CPU
backend, and transcribe.cpp on Metal, which is what the Mac app ships.

| | English, 647 clips, 14,481 words | Russian, 775 clips, 15,105 words | Both |
|---|---|---|---|
| transcribe.cpp, CPU | 727 errors, 5.02% | 746 errors, 4.94% | 1,473, 4.98% |
| engine | 723 errors, 4.99% | 749 errors, 4.96% | 1,472, 4.98% |
| transcribe.cpp, Metal | 735 errors, 5.08% | 735 errors, 4.87% | 1,470, 4.97% |

| Clips whose text differs from transcribe.cpp's CPU backend | English | Russian | Both |
|---|---|---|---|
| engine | 61 | 69 | 130 of 1,422 |
| transcribe.cpp, Metal | 60 | 69 | 129 of 1,422 |

Among the 130 clips where the engine's text differs, 27 have fewer word
errors than the CPU backend's and 24 have more.

Reading. The engine does not give the same text on every clip, and no two
implementations of this model do. transcribe.cpp's own two backends differ on
129 clips. The differences are spellings the model is undecided about, e.g.,
"wild card" and "wildcard". Token times differ on about half the clips for
both pairs, because the frame a token is written at moves by one.

The reason is in the arithmetic. Activations are rounded to 8 bits before
every product, so a difference in the last bit of a float sometimes rounds
the other way, and after 24 blocks the two encoders agree to about 2%.
Layer by layer, the engine's mel features match transcribe.cpp's to one part
in a million, block 0 to 0.15%, and the last block to 3.6%
(`cmp_dumps.py`, on the fork's validation build).

Decision. The gate is word error rate, and it passes: 1,472 errors against
1,473 and 1,470 in 29,586 words.

## P2. Taught words

Method. The 70 spoken sentences and 60 terms of
`research/term-biasing-2026-10`, both runtimes on the CPU, with the terms
off and on.

| Terms found | transcribe.cpp off | transcribe.cpp on | engine off | engine on |
|---|---|---|---|---|
| English, test half | 23 of 37 | 32 of 37 | 23 of 37 | 32 of 37 |
| English, dev half | 27 of 41 | 34 of 41 | 27 of 41 | 34 of 41 |
| Russian, test half | 1 of 34 | 1 of 34 | 3 of 34 | 3 of 34 |
| Russian, dev half | 1 of 31 | 1 of 31 | 1 of 31 | 1 of 31 |

On the first 200 FLEURS clips of each language, with all 60 terms on, the
terms changed 1 English and 3 Russian transcripts in transcribe.cpp and 2
and 3 in the engine.

On the 358 of those 400 clips where the two runtimes agree without the
terms, they agree on all 358 with them, and the transcripts that change are
the same ones, e.g., "Sapufila" becomes "Supabase" in both.

Decision. The port of the phrase-boost automaton behaves as the fork's does.

## L1. Audio longer than 30 seconds

The app never gives the engine more than 30 s. For completeness the engine
ports transcribe.cpp's segmenter: a clip past the model's limit is cut at
pauses found by the model's own speech-detection head and recognized piece by
piece (`ore_longform.c`, commit `26ae0d9`).

Test. Three clips from the fork's samples, 609 s in all, both runtimes on the
M4 Pro with four threads.

| Clip | Words in each runtime | Words that differ |
|---|---|---|
| 70 s | 170 | 0 |
| 233 s | 638 | 0 |
| 306 s | 812 | 3 |

The three are "it, no" against "it. No", "why'd" against "why did", and
"working class" against "working-class". The last token has the same time in
both runtimes on each clip, so the cuts fall on the same samples. The 70 s
clip gives identical text in both runtimes on every hosted machine (run
45044832938).

A model without the speech-detection head (the v3 family) is refused past
120 s.

## X1. The same output on every machine

Method. The hosted job prints a checksum of the engine's output for four
sample clips: text, token ids, times, and confidences to six decimals.

First result (run 45034315337). The checksum was the same on the M1, both
Intel Mac jobs and Linux arm64, and different on Linux x86-64 and Windows.
On Linux x86-64 the cause was glibc's single-precision `tanh`, `sin`, `cos`
and `exp`, which round differently there. The engine now uses its own `exp`
and the double-precision functions rounded once (commit `26ae0d9`).

Result (run 45044832938). macOS arm64, Linux arm64, Linux x86-64 on two
different processors and the Intel Mac give the same checksum. On every
machine the plain C table and the vector table give the same output.

Windows. In run 45044832938 both Windows machines gave one checksum, which
was not the others'. The cause was the two-byte line endings of the file the
checksum is taken of. The workflow now leaves them out.

Result (run 45046209178, commit `e7f8137`). All seven machines print
`30b41b143a18db2d`: Windows x86-64 twice, Linux x86-64 on two processors,
one of them with the `avx512` set, Linux arm64, the Apple M1 and the Intel
Mac. The M4 Pro prints the same.

Against transcribe.cpp on those four clips: the text is identical on every
machine, and all 282 token ids are equal. Three token times differ by one
encoder frame of 80 ms, which is why the job logs say "tokens and times:
DIFFERENT".

## R1. Memory, load time and size

M4 Pro, Parakeet Ultra Q4_K_M, four threads, `/usr/bin/time -l`.

| | engine | transcribe.cpp, CPU |
|---|---|---|
| Peak memory footprint, 8 s clip | 118 MB | 479 MB |
| Peak memory footprint, 30 s clip | 159 MB | 583 MB |
| Model load, file already in the cache | 21 to 27 ms | 83 to 93 ms |
| Instructions for an 8 s clip | 35 billion | 80 billion |
| Static library | 146 KB | several megabytes |
| Source | 7,300 lines of C | 100,000 lines and ggml |

The engine maps the model file and uses the weights where they lie, so they
are file pages the system can drop and reload. transcribe.cpp 0.4.1 copies
them. A cold first load reads the 486 MB file from disk in both cases.

## A1. What the built library asks of the system

`engine/scripts/check-symbols.sh` lists every symbol `libore.a` leaves for
the system to supply and fails on any outside a short list: memory, strings,
math, sorting, one file mapped read-only, a clock, threads, and the
compiler's own helpers. There is no socket, no loader, no process and no
environment variable. The hosted job runs it on Linux and macOS, and it
passes (run 45044832938). The repository's own
`scripts/check-network-surface.sh` passes with `engine/` present, and
`ore-cli` gives the right sentence when the system denies it all network
access (`sandbox-exec` with `deny network*`).

## S1. Speed, whole recognitions

Two hosted runs are recorded, because GitHub gives a different processor
each time. Run 45046209178 is the final code (commit `e7f8137`). Run
45044832938 is the code before the `avx512` set. Best of three, wall time in
milliseconds, engine against transcribe.cpp at the same number of threads.
Every machine has four logical processors. `tools/speed_table.py` prints
every clip length from the files in `data/`.

Both runtimes read the Q4_K_M file in every table of S1. Windows and Linux
ship the Q8_0 file, so "as shipped" in S1 means the shipped build and not
the shipped model file. S2 has the comparison with the Q8_0 file. The Intel
Mac does ship Q4_K_M, so its rows compare what ships.

### Run 45046209178, the final code

One thread:

| Machine, and how transcribe.cpp was built | 8 s clip | 30 s clip |
|---|---|---|
| Windows, EPYC 7763, as shipped (the build chose AVX2) | 1,353 against 2,088, 1.5 times | 5,153 against 7,845, 1.5 times |
| Windows, EPYC 7763, built for AVX2 | 1,332 against 2,074, 1.6 times | 5,022 against 7,833, 1.6 times |
| Intel Mac, i7-8700B, as shipped | 2,435 against 4,867, 2.0 times | 9,836 against 14,750, 1.5 times |
| Intel Mac, i7-8700B, built for AVX2 | 1,983 against 2,495, 1.3 times | 7,020 against 9,696, 1.4 times |
| Linux arm64, Neoverse-N2 | 1,953 against 5,376, 2.8 times | 7,457 against 18,441, 2.5 times |
| Linux x86-64, EPYC 9V74, built for AVX2 | 1,107 against 1,636, 1.5 times | 4,158 against 6,188, 1.5 times |
| Linux x86-64, EPYC 9V45, built for that processor | 623 against 613, 0.98 times | 2,246 against 2,210, 0.98 times |
| Apple M1, CPU only | 1,102 against 2,112, 1.9 times | 4,702 against 9,102, 1.9 times |

Four threads:

| Machine | 8 s clip | 30 s clip |
|---|---|---|
| Windows, as shipped | 688 against 1,102, 1.6 times | 2,538 against 3,906, 1.5 times |
| Windows, built for AVX2 | 688 against 1,102, 1.6 times | 2,523 against 3,862, 1.5 times |
| Intel Mac, as shipped | 892 against 1,935, 2.2 times | 3,329 against 6,611, 2.0 times |
| Intel Mac, built for AVX2 | 708 against 915, 1.3 times | 2,625 against 3,360, 1.3 times |
| Linux arm64 | 545 against 1,392, 2.6 times | 2,188 against 4,778, 2.2 times |
| Linux x86-64, built for AVX2 | 520 against 836, 1.6 times | 1,858 against 2,939, 1.6 times |
| Linux x86-64, built for that processor | 313 against 355, 1.1 times | 1,195 against 1,158, 0.97 times |
| Apple M1, CPU only | 474 against 854, 1.8 times | 1,916 against 3,354, 1.8 times |

The `sse` set on the same machines with AVX2 switched off in software, 8 s
clip on one and on four threads: 2,815 and 1,241 ms on the Windows EPYC
7763, 3,294 and 1,111 ms on the Intel Mac, 2,407 and 1,082 ms on the EPYC
9V74, 1,789 and 766 ms on the EPYC 9V45. The shipped transcribe.cpp builds
need at least AVX, so these have no baseline. In the Intel Mac job
that built transcribe.cpp as shipped, the `sse` set took 3,091 and 1,225 ms.

### Run 45044832938, before the `avx512` set

Every row but the Intel Mac as shipped, which is run 45034315337.

One thread:

| Machine, and how transcribe.cpp was built | 8 s clip | 30 s clip |
|---|---|---|
| Windows, Xeon Platinum 8573C, as shipped (the build chose AVX-512) | 1,622 against 3,396, 2.1 times | 6,513 against 13,038, 2.0 times |
| Windows, EPYC 9V74, built for AVX2 | 1,158 against 1,644, 1.4 times | 4,424 against 6,366, 1.4 times |
| Intel Mac, i7-8700B, as shipped | 1,704 against 3,836, 2.3 times | 5,089 against 14,309, 2.8 times |
| Intel Mac, i7-8700B, built for AVX2 | 1,916 against 2,867, 1.5 times | 9,020 against 11,181, 1.2 times |
| Linux arm64, Neoverse-N2 | 1,907 against 5,225, 2.7 times | 7,525 against 18,321, 2.4 times |
| Linux x86-64, EPYC 7763, built for AVX2 | 1,479 against 2,122, 1.4 times | 5,870 against 8,067, 1.4 times |
| Linux x86-64, EPYC 9V74, built for that processor | 1,227 against 1,017, 0.83 times | 4,677 against 3,986, 0.85 times |
| Apple M1, CPU only | 1,093 against 2,381, 2.2 times | 4,576 against 9,145, 2.0 times |

Four threads:

| Machine | 8 s clip | 30 s clip |
|---|---|---|
| Windows, as shipped | 830 against 1,662, 2.0 times | 3,179 against 5,738, 1.8 times |
| Windows, built for AVX2 | 594 against 936, 1.6 times | 2,245 against 3,234, 1.4 times |
| Intel Mac, as shipped | 707 against 2,073, 2.9 times | 2,937 against 6,599, 2.2 times |
| Intel Mac, built for AVX2 | 776 against 1,049, 1.4 times | 2,861 against 3,796, 1.3 times |
| Linux arm64 | 540 against 1,396, 2.6 times | 2,154 against 4,724, 2.2 times |
| Linux x86-64, built for AVX2 | 703 against 1,013, 1.4 times | 2,659 against 3,568, 1.3 times |
| Linux x86-64, built for that processor | 617 against 544, 0.88 times | 2,265 against 1,975, 0.87 times |
| Apple M1, CPU only | 567 against 1,004, 1.8 times | 2,048 against 3,632, 1.8 times |

### What the two runs say together

**Windows depends on the processor.** "As shipped" leaves the instruction
set to the build machine. On the Xeon the build chose AVX-512 and
transcribe.cpp took 3,396 ms for the 8 s clip. On the EPYC 7763 it chose
AVX2 and took 2,088 ms. The engine took 1,622 and 1,353 ms. So the engine is
2.1 times faster at equal threads on one Windows machine and 1.5 times on
the other. Why the AVX-512 build is that slow on the Xeon was not
investigated.

**MSVC and GCC build transcribe.cpp to the same speed.** On the EPYC 7763
the AVX2 build takes 2,074 ms on Windows and 2,122 ms on Linux. On the EPYC
9V74 it takes 1,644 and 1,636 ms.

**One thread shipped against four.** The app gives recognition one thread on
Windows and Linux. Against that, the engine on four threads takes 688 ms
where transcribe.cpp takes 2,088 ms on the EPYC 7763 (3.0 times), 830 against
3,396 ms on the Xeon (4.1 times), and 545 against 5,376 ms on Linux arm64
(9.9 times).

**The Intel Mac runner varies.** It is a shared machine. The same engine
code took 1,983 ms and 2,435 ms for the 8 s clip on one thread in two jobs
of one run, and a second pass inside the slower job took 2,016 ms. Its
ratios are therefore ranges.

**The Intel Mac against what it ships.** Intel Macs ship the as-shipped
build with Q4_K_M on four threads, so the four-thread row is the comparison
with what people have. Three runs give, engine against transcribe.cpp:

| Run | 8 s clip, four threads | 30 s clip, four threads |
|---|---|---|
| 45034315337 | 707 against 2,073, 2.9 times | 2,937 against 6,599, 2.2 times |
| 45046209178 | 892 against 1,935, 2.2 times | 3,329 against 6,611, 2.0 times |
| 45047905043 | 1,080 against 2,306, 2.1 times | 3,710 against 7,134, 1.9 times |

**The decoder is the engine's weak part on the Intel Mac.** On one thread it
takes 274 ms of the 8 s clip where transcribe.cpp, which uses Apple's
Accelerate there, takes 151 ms. On four threads it is 174 against 154 ms.

### The M4 Pro

On the M4 Pro (two alternating rounds, load average 7 to 9, best of ten),
engine against transcribe.cpp's CPU backend, in milliseconds:

| Clip | One thread | Two threads | Four threads |
|---|---|---|---|
| 2 s | 190 against 335 | 107 against 183 | 59 against 99 |
| 8 s | 704 against 1,302 | 383 against 709 | 198 against 403 |
| 30 s | 2,886 against 5,415 | 1,464 against 2,798 | 771 against 1,568 |

The engine is 1.8 to 2.0 times the CPU backend there. Metal, which the Mac
app ships, takes 80 ms for the 8 s clip and 142 ms for 15.8 s. Metal is 2.5
times faster than the engine on four threads, and 1.7 times faster than the
engine on eight (133 ms), so the Mac app on Apple silicon keeps Metal.

## S2. Against what Windows and Linux ship: the Q8_0 file

Question. Windows and Linux ship `parakeet-ultra-Q8_0.gguf` on one thread,
because October's H13 found that ggml runs Q4_K_M 1.3 times slower than Q8_0
on the M4 Pro's processor. S1 used Q4_K_M in both runtimes. If H13 held on
the hosted machines, the runtime people have today would be faster than
S1's transcribe.cpp column and the engine's gain smaller.

Method (run 45047905043, commit `5a85844`, the five Linux and Windows jobs).
Each job downloads the Q8_0 file, checks its hash, compares the text of both
runtimes on the four sample clips, and times both runtimes with it on 1, 2
and 4 threads for clips of 2, 8 and 30 s, best of three. The Q4_K_M tables
come from the same job. GitHub gave these processors: an EPYC 7763 to both
Linux x86-64 jobs, an EPYC 9V74 to the Windows job with the default build,
which chose AVX-512, and a Xeon Platinum 8573C to the Windows job with the
AVX2 build.

Result 1. The engine runs the Q8_0 file. Its text is identical to
transcribe.cpp's on the four clips on all five machines.

Result 2. H13 does not hold on these machines. transcribe.cpp runs Q8_0
slower than Q4_K_M on every x86 machine and 5% faster on Linux arm64.

| transcribe.cpp, 8 s clip, one thread, ms | Q8_0 | Q4_K_M |
|---|---|---|
| Linux x86-64, EPYC 7763, default build | 2,200 | 1,816 |
| Linux x86-64, EPYC 7763, AVX2 build | 2,213 | 2,022 |
| Windows, EPYC 9V74, default build | 2,066 | 1,753 |
| Windows, Xeon 8573C, AVX2 build | 3,258 | 2,433 |
| Linux arm64, Neoverse-N2 | 4,922 | 5,199 |

So the runtime people have today is slower than S1's transcribe.cpp column
on x86, and the engine's gain against it is larger than S1 shows.

Result 3. At the same number of threads, transcribe.cpp with Q8_0 against
the engine with each file, in milliseconds. The ratio is transcribe.cpp's
time divided by the engine's.

| 8 s clip | Threads | transcribe.cpp, Q8_0 | engine, Q4_K_M | engine, Q8_0 |
|---|---|---|---|---|
| Linux x86-64, EPYC 7763 | 1 | 2,200 | 1,424, 1.5 times | 1,670, 1.3 times |
| | 2 | 1,129 | 769, 1.5 times | 860, 1.3 times |
| | 4 | 1,137 | 717, 1.6 times | 848, 1.3 times |
| Windows, EPYC 9V74 | 1 | 2,066 | 1,246, 1.7 times | 1,511, 1.4 times |
| | 2 | 1,072 | 658, 1.6 times | 809, 1.3 times |
| | 4 | 1,034 | 600, 1.7 times | 734, 1.4 times |
| Windows, Xeon 8573C | 1 | 3,258 | 1,303, 2.5 times | 1,668, 2.0 times |
| | 2 | 1,761 | 703, 2.5 times | 889, 2.0 times |
| | 4 | 1,650 | 960, 1.7 times | 844, 2.0 times |
| Linux arm64, Neoverse-N2 | 1 | 4,922 | 1,862, 2.6 times | 1,927, 2.6 times |
| | 2 | 2,494 | 989, 2.5 times | 1,002, 2.5 times |
| | 4 | 1,309 | 530, 2.5 times | 542, 2.4 times |

| 30 s clip | Threads | transcribe.cpp, Q8_0 | engine, Q4_K_M | engine, Q8_0 |
|---|---|---|---|---|
| Linux x86-64, EPYC 7763 | 1 | 8,688 | 5,523, 1.6 times | 6,208, 1.4 times |
| | 4 | 4,428 | 2,662, 1.7 times | 3,084, 1.4 times |
| Windows, EPYC 9V74 | 1 | 8,243 | 4,674, 1.8 times | 5,558, 1.5 times |
| | 4 | 4,100 | 2,187, 1.9 times | 2,630, 1.6 times |
| Windows, Xeon 8573C | 1 | 12,722 | 5,176, 2.5 times | 6,358, 2.0 times |
| | 4 | 6,218 | 3,484, 1.8 times | 3,132, 2.0 times |
| Linux arm64, Neoverse-N2 | 1 | 17,533 | 7,235, 2.4 times | 7,093, 2.5 times |
| | 4 | 4,503 | 2,009, 2.2 times | 1,967, 2.3 times |

The Xeon has two cores with two threads each, and its four-thread cells are
unsteady. The engine with Q4_K_M was slower there on four threads than on
two. Over every cell of the run, 2 s clips included, the lowest ratio is
1.18 (engine with Q8_0, EPYC 7763, 2 s clip, four threads).

Result 4. Against what a person has today, which is transcribe.cpp with
Q8_0 on one thread, the engine with Q4_K_M:

| 8 s clip, ms | today | engine, two threads | engine, four threads |
|---|---|---|---|
| Linux x86-64, EPYC 7763 | 2,200 | 769, 2.9 times | 717, 3.1 times |
| Windows, EPYC 9V74 | 2,066 | 658, 3.1 times | 600, 3.4 times |
| Windows, Xeon 8573C | 3,258 | 703, 4.6 times | 960, 3.4 times |
| Linux arm64, Neoverse-N2 | 4,922 | 989, 5.0 times | 530, 9.3 times |

For the 30 s clip the same comparison gives 3.0 and 3.3 times on the EPYC
7763, 3.4 and 3.8 times on the EPYC 9V74, 4.8 and 3.7 times on the Xeon, and
4.5 and 8.7 times on Linux arm64.

Result 5. In the engine, Q4_K_M is 10 to 20% faster than Q8_0 on x86 and
within 4% of it on Linux arm64. The 8-bit product needs a correction for
signed weights that the 4-bit product does not.

Decision. The engine should be given the Q4_K_M file on every platform. It
is the faster file in the engine and 254 MB smaller, it is the file the Mac
already ships, and P1 measured its word errors. With either file the engine
is faster than what ships on every machine and thread count measured.

Limits. One run, three clip lengths, and one processor of each kind. The
1.5 to 1.7 times on the AMD machines is the gain a person with a two-core
computer would see if the app gave transcribe.cpp the same threads.

## Not done

- **The engine is not in the app.** It is not behind `ramble-engine` or the
  Swift adapter. Putting it there changes what ships and waits for Mik's
  yes. Two things the adapter uses have no counterpart yet: a call that
  recognizes several clips at once, and the detected language.
- **The kernel choice on Windows on an AMD Zen 4 processor.** The `avx512`
  set was 10% slower there than `avx2`. The change for it is in the code, and
  the engine picks the new table on that processor under Linux. It has not
  been timed under Windows (K7).
- **Word errors with the Ultra Q8_0 file in the engine.** The four sample
  clips give identical text. The 1,422 FLEURS clips were run with Q4_K_M,
  which is the file S2 recommends.
- **Four threads on a busy Windows or Linux machine.** T1 has three rounds
  on the Mac.
- **A fixed cost of 20 to 60 ms per recognition.** The engine decodes the
  headers of about 2 million weight blocks every time. It shows on short
  clips: 206 against 184 ms for 2 s on the EPYC 9V45. Keeping the decoded
  headers would cost about 47 MB of memory.
- **4-bit weights for the two 1x1 convolutions.** They are stored in half
  precision and multiplied in single precision, at 15 to 49 billion
  multiply-adds a second where the 4-bit kernel does 42 to 134. They are 12%
  of the arithmetic and about 30% of the time. Quantizing them needs a
  converted model file and a word-error gate.
- **Arm's 8-bit matrix extension**, which the M2 and later, Neoverse-N2 and
  Snapdragon X have. The dot-product kernel is at the limit of two
  multiplier units.
- **A cache of the position projections.** They depend only on the clip's
  length and are 8% of the arithmetic.
- **Smaller costs left as they are.** The mel step runs on one thread (14 ms
  of a 30 s clip), and the decoder's output layer is still single precision.
- **Recognizing closed stretches of a take while the person still speaks.**
  On a slow computer the wait after key-up is the engine's time per second of
  audio times the length of what is left to recognize. Faster kernels shrink
  the first factor, and cutting at pauses while speaking shrinks the second.
  That is a change to the app's segmenter, not to the engine, and it was not
  measured here.
- **A graphics path.** Not built. On Windows and Linux a graphics processor
  would likely beat any CPU kernel on machines that have a working driver,
  and no such machine can be measured from here.
- **Windows on Arm.** The code has the paths for it. It was not built or run.
- **Why calling ggml's routine directly fails on Linux and Windows** (K3).
