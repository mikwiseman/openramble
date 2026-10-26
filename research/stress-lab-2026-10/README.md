# Dictation on an overloaded Mac

The question: does a dictation still land, whole and fast, when every core is
busy, when the Mac is short of memory, when both happen at once, and when the
model has sat unused long enough for macOS to page it out? This folder holds
the lab that answers it, the numbers, and what changed because of them.

## The lab

`./scripts/stress-lab.sh <label> [conditions]` runs
`apps/macos/OpenRambleTests/StressLab.swift`. It builds the real `AppState`,
the same object the app runs, with the real microphone capture, the real model
and engine, the real text pipeline, the real HUD and the real paste. Two edges
are stand-ins:

- The key is pressed and released in code.
- The built-in microphone is opened, started and read exactly as in a take,
  but each buffer's samples are replaced with a recorded sentence on their way
  in. Recognition gets words, and nothing the room says is kept.

The paste goes to a private named pasteboard, never the general one, and a
second process reads it the way TextEdit reads ⌘V. That read is the "target
read" time. The lab is opt-in and skipped by `check.sh`: it opens the
microphone, and it never asks for a permission it does not have.

Each take records time from release to ⌘V and to the target's read, key-down
to the first audio the capture receives, the engine time, device cycles that
never reached the capture ("lost frames", from the device's own sample times),
the main thread's longest stall (a 10 ms heartbeat; the HUD and every
main-actor step of a take run there), the bytes the process read from disk,
and whether the pasted text matches the sentence spoken.

Conditions:

| Condition | What it does |
|---|---|
| quiet | nothing added |
| cpu | one busy process per logical CPU (14), at the default priority, as in the October 9 benchmark |
| memory | a bounded hog keeping 8 GB of incompressible pages hot, so macOS has to page everything else out |
| both | cpu and memory together |
| idle | the hog, then one take after each 240 s of rest: the 23 October shape |

`memory_pressure -S -l critical` was considered and not used for the memory
conditions: it holds the system at an artificial level and moves no page, so
it cannot reproduce a model read back from swap.

Takes alternate between a 3.8 s sentence and a 21 s passage with pauses (the
passage is long enough to stream one piece while it is spoken). Builds are
compared by running the same lab file against each, alternating which goes
first per condition, so the drift of a shared Mac lands on both.

## What it found

Measured 26 October 2026 on the MacBook Pro M4 Pro (24 GB, macOS 27.0.1) that
runs everything else too. Other sessions were building, testing and
launching hundreds of processes during the runs: the "Load" column is the
median one-minute load average during each group's takes, and it swung from 6
to over 100. Adjacent runs of the two builds can sit at very different load,
so a 10–30% latency difference between two rows here is not a finding.

### Final run: 0.33.1 against this branch

`python3 -I summarize.py data/final/0.33.1-takes.jsonl data/final/fixed-takes.jsonl`
(milliseconds; 6 takes per row, 4 for idle):

| Condition | Take | Build | Landed | Words missed | Release → ⌘V p50 / p95 | Key-down → first audio p50 / p95 | Engine p50 / p95 | Lost frames (takes) | Main-thread stalls > 100 ms | Longest stall | Load |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| quiet | short | 0.33.1 | 6 | 0 | 119 / 137 | 64 / 108 | 117 / 135 | 0 (0) | 0 | 2 | 6 |
| quiet | short | fixed | 6 | 0 | 138 / 214 | 64 / 186 | 134 / 209 | 0 (0) | 0 | 49 | 10 |
| quiet | long | 0.33.1 | 6 | 0 | 135 / 149 | 61 / 66 | 130 / 139 | 0 (0) | 0 | 4 | 6 |
| quiet | long | fixed | 6 | 0 | 170 / 282 | 65 / 103 | 166 / 266 | 3700 (1) | 0 | 74 | 10 |
| cpu | short | 0.33.1 | 6 | 0 | 178 / 236 | 105 / 195 | 165 / 203 | 0 (0) | 0 | 51 | 166 |
| cpu | short | fixed | 6 | 0 | 177 / 194 | 109 / 177 | 164 / 189 | 0 (0) | 0 | 7 | 69 |
| cpu | long | 0.33.1 | 6 | 0 | 184 / 223 | 73 / 120 | 161 / 205 | 0 (0) | 0 | 19 | 173 |
| cpu | long | fixed | 6 | 0 | 191 / 206 | 81 / 221 | 174 / 183 | 0 (0) | 0 | 39 | 75 |
| memory | short | 0.33.1 | 6 | 1 | 830 / 1422 | 499 / 1128 | 739 / 1368 | 816 (1) | 4 | 1708 | 90 |
| memory | short | fixed | 6 | 4 | 421 / 580 | 286 / 1430 | 409 / 459 | 0 (0) | 5 | 3695 | 31 |
| memory | long | 0.33.1 | 6 | 0 | 510 / 760 | 254 / 413 | 399 / 580 | 2484 (1) | 3 | 290 | 88 |
| memory | long | fixed | 6 | 0 | 354 / 539 | 222 / 393 | 273 / 439 | 4284 (2) | 1 | 115 | 29 |
| both | short | 0.33.1 | 6 | 0 | 290 / 2591 | 137 / 391 | 286 / 2570 | 3316 (1) | 0 | 62 | 114 |
| both | short | fixed | 6 | 0 | 808 / 1819 | 209 / 595 | 596 / 1644 | 2252 (1) | 1 | 2096 | 79 |
| both | long | 0.33.1 | 6 | 0 | 216 / 288 | 115 / 197 | 199 / 219 | 0 (0) | 0 | 61 | 123 |
| both | long | fixed | 6 | 0 | 511 / 1052 | 209 / 430 | 421 / 894 | 0 (0) | 3 | 241 | 77 |
| idle | short | 0.33.1 | 4 | 1 | 937 / 1534 | 336 / 1158 | 837 / 1422 | 10328 (3) | 5 | 2814 | 13 |
| idle | short | fixed | 4 | 0 | 397 / 745 | 517 / 792 | 346 / 547 | 4940 (3) | 5 | 1173 | 21 |

Every take of both builds landed, in every condition: no dictation was lost.
The earlier runs are in `data/explore-*`: `explore-1/run-log.txt` is the first
baseline (its journal was overwritten per run by a lab bug since fixed, so only
its last conditions have rows), `explore-2` tested the ring against 0.33.1
under memory pressure, `explore-3` tested priming the ring.

### Every core busy: the path holds

With one busy process per logical CPU, release → ⌘V rose from about 120–140 ms
to 135–190 ms at the median across all runs, and no take lost a word or a
dictation. Every thread a take depends on already runs at `userInteractive`
(the audio hand-off, the converters, the engine's own queue) and the engine's
decoder uses one thread, so fourteen default-priority spinners mostly lose to
it. Raising priorities further has nothing left to win, and was not changed.

### Memory pressure: page faults everywhere

Under the hog the same path costs 120–830 ms at the median and up to 2.6 s at
p95, depending on how loaded the shared Mac was. Two things grow:

- The engine. A temporary breakdown of the runtime's own timings showed the
  GPU encoder going from about 100 ms to 296 ms on a long take's tail under
  CPU and memory load, while the CPU decoder went from 25 to 57 ms and the
  take read almost nothing from disk. The weights stay resident while takes
  keep coming, inside ggml's three-minute keep-alive; what slows is the GPU
  sharing power and memory bandwidth with an overloaded Mac.
- Everything else in the process. The first take after the hog starts pages
  the app back in: the main thread froze 1.2–3.7 s at the key-down on both
  builds, and the microphone's first audio arrived 1.2–1.7 s after the press.

The paste itself holds: ⌘V went out 1–33 ms after the text at the median in
every condition, at most 379 ms. The target's read after it slowed to 59–275 ms
at the median, which is the other process paging in, not OpenRamble.

### After a rest under pressure: the 23 October take

0.33.1 reproduced it: engine 837 ms at the median, release → ⌘V 937 / 1534 ms,
a word missed. With the warm-up at key-down the engine ran 346 ms and ⌘V came
397 / 745 ms after release, the page-in having happened while the sentence was
spoken. `research/idle-swap-2026-10` measured the same change on its own with
`asr-bench`: 1.06 s → 0.14 s median from key-up to text.

### Lost audio

`python3 -I losses.py`, every run in `data/`:

| Capture | Takes | Losses of one cycle (device gap < 30 ms) | Longer losses (gap ≥ 30 ms) |
|---|---:|---:|---:|
| 0.33.1 design (queue) | 116 | 7 | 8 |
| This branch (ring) | 98 | 1 | 7 |

On 0.33.1 the HAL waited for a dispatch queue inside each 10.7 ms cycle, and a
queue thread 23–28 ms late cost exactly one cycle. The ring removed that
class. What remains are losses where the device's own real-time thread was
38–88 ms late, during stalls of the whole process: in the clearest one the
main thread stalled 74 ms at the same instant. Of the longer losses whose
position was recorded, 8 of 11 fall on a take's second cycle, after a rest or
as the load starts, where the built-in microphone is still delivering its
~180 ms of near-silence (the lab starts its sentence on the first buffer, so
it counts them as speech); 3 fell mid-sentence, 8.7–13 s into a take. Before
this branch these losses left no trace; now the journal and speed line carry
`lost`.

### What was tried and not kept

| Candidate | Why not |
|---|---|
| Higher QoS for audio and inference | Already `userInteractive`; all cores busy cost 1.1–1.5×. |
| File-backed (mapped) weights | transcribe.cpp's load parameters are backend and device only; it would mean patching the runtime. Under ongoing pressure takes read almost nothing from disk, and after a rest the warm-up covers the read. |
| Warm-up on every press under pressure | The slowdown under ongoing pressure is GPU time with no page-in; a warm-up cannot change it. |
| Running the ring's copy once before the device starts | Losses at the start of a take after a rest did not fall (3 of 4 idle takes still lost a cycle). |
| `memory_pressure -S -l critical` | Sets an artificial level and moves no page; it cannot reproduce a read back from swap. |
| Main-thread work during a take | The stalls are page faults at the key-down after a page-out, not work: in quiet runs the main thread's longest stall was 2–74 ms. |

### Open

The first take after the Mac pages OpenRamble out starts its microphone
1.2–1.7 s after the key-down and freezes the HUD for 1.2–3.7 s, on both builds.
Words spoken in that window are lost. The cause is page faults across the
start path and the main thread (80–127 MB read on those takes); the capture
already starts before any HUD work. Nothing here fixes it, and opening the
microphone before the key-down is ruled out by the app's privacy promise.

### Against Handy

The October 9 product benchmark ran Handy's and OpenRamble's command-line
transcription under the same fourteen busy processes: median 0.511 s against
1.134 s, p95 0.731 s against 2.872 s (`research/product-benchmark-2026-10`). A
live comparison of the whole path would need Handy's own hotkey, microphone
and paste driven by hand, and was not done.

### Which runtime this measured

The app's Swift engine does not call the transcribe.cpp 0.4.0 framework it
pins. `RambleCoreFFI` links the Rust crate `transcribe-cpp-sys` 0.2.0
statically, and every `transcribe_*` call the app makes resolves to that copy;
shipping 0.33.1 imports only two whisper helpers from the 0.4.0 framework
(`dyld_info -imports`). The lab's test bundle links the same way, so these
numbers describe the runtime the app really runs. Untangling the two is a
separate change.
