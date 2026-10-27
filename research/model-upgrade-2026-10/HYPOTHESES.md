# Hypothesis ledger

Every hypothesis about the model and the runtime is recorded here with its
gate, its result and the decision, including the ones that fail. Each entry
links to the evidence. The scorecard is in `research/scorecard/`; candidate
files are in `research/scorecard/candidates/`; results are in
`research/scorecard/results/`.

## H1. Runtime 0.4.0 is a safe drop-in for 0.2.3 with v3

Gate: Part 1 of `PREREGISTRATION.md`.

Result so far:

- On all 1,422 FLEURS English and Russian test utterances, 1,420 transcripts are
  identical. In one English utterance 0.4.0 replaces an inserted "and in" with
  "and", which leaves the error count unchanged. In one Russian utterance 0.4.0
  no longer prints a literal `<unk>` at the end, which upstream fixed in
  "remove unk" (#182). The pooled WER difference is −0.003 percentage points,
  with a 95% interval from −0.01 to 0.00.
- Wrong-script decodes (20 of 199 private clips, 0 of 1,422 FLEURS) and
  invented words on noise (0) are unchanged.
- Hour-file deleted-word rates are unchanged (English 4.80%, Russian 1.71%);
  the alternating hour's WER moves from 39.07% to 39.04%.
- The LocalASR end-to-end tests with the model pass under both runtimes (21
  tests, 3 skipped, 0 failures), and the unit tests pass (163 tests, 9 skipped).
- The runtime binary passes the network audit.
- Speed and memory, in the interleaved speed run: over all speed inputs, warm
  p50 327.4 against 323.5 ms and p95 1,482 against 1,459 ms idle, 415.7
  against 413.6 ms and 2,010 against 1,988 ms under load, whole-process p50
  0.429 against 0.431 s, peak memory 1.07 against 1.02 GB. All within the
  preregistered limits. On short takes alone (under 15 s) 0.4.0 is about 8%
  slower: p50 78 against 72 ms, p95 132 against 122 ms. That passes the rule,
  which pools all inputs, and it is the cost to watch.

Decision: all seven rules pass; runtime 0.4.0 is adopted.

## H2. A runtime built from source is equivalent to the upstream binary

`scripts/build-transcribe-xcframework.sh` built transcribe.cpp v0.4.0
(`f1dcd158`) with upstream's own scripts. The build passes the same audit and
exports the same 217 symbols as the upstream binary.

Result: on all 1,422 FLEURS utterances, the 11 noise clips and the 199 private
clips, the transcripts of the source build are byte-identical to the upstream
binary's.

Decision: accepted. A build of our own can replace the upstream download
without changing recognition, which is the precondition for shipping runtime
changes before they merge upstream.

## H3. One model beats v3 on the preregistered rule

Gate: Part 2 of `PREREGISTRATION.md`.

Result so far, all on transcribe.cpp 0.4.0 with no language hint:

| | v3 | Parakeet Ultra | Nemotron 3.5 |
|---|---:|---:|---:|
| Pooled WER, 1,422 FLEURS utterances | 5.51% | 4.78% | 11.91% |
| Difference from v3, 95% interval | | −0.74 (−0.91 to −0.56) | +6.40 (+5.80 to +7.02) |
| English / Russian WER | 5.45% / 5.57% | 4.91% / 4.64% | 11.42% / 12.39% |
| Wrong script, private + FLEURS | 20 / 1,621 | 0 / 1,621 | 0 / 1,621 |
| Invented words on noise | 0 | 0 | 0 |
| Hour deleted words, English / Russian | 4.80% / 1.71% | 2.97% / 0.79% | 3.21% / 1.08% |
| Alternating hour WER | 39.04% | 39.79% | 46.80% |
| Punctuation F1, English / Russian | 80.9% / 90.8% | 83.3% / 92.6% | 78.0% / 85.3% |
| Capitalization F1, English / Russian | 91.4% / 90.9% | 92.9% / 92.8% | 89.0% / 88.4% |

Parakeet Ultra passes gates 1, 2, 3, 4 and 7 and the WER rule. Nemotron fails
the WER rule by a wide margin, so it is not eligible whatever its speed.
Ultra's zero wrong-script count is not empty output: its 199 private
transcripts have a median of 14 words and no Cyrillic letter at all, where
v3's contain 738 Cyrillic letters.

Speed and memory, interleaved with the others: Ultra's warm p95 is 1,615
against 1,482 ms idle and 2,126 against 2,010 ms under load (both within
1.15 times v3), its short-take p50 and p95 are 75 and 125 ms (v3 on 0.4.0: 78
and 132), and its peak memory is 1.06 against 1.07 GB. Nemotron's warm p95 is
2,846 and 4,151 ms, beyond the limit. `decide.py` applies every rule and
writes `decision.json`.

Decision: Parakeet Ultra passes the WER rule and all seven gates and is the
recommended model. Nemotron fails the WER rule and gates 4, 5 and 7.

## H4. Phrase boosting raises term recall without hurting general speech

Gate: `research/term-biasing-2026-10/PREREGISTRATION.md` on branch
`claude/term-biasing`. Runtime change: Aho-Corasick phrase boosting in the
Parakeet greedy decoders, honoring `transcribe_run_params::vocabulary`
(transcribe.cpp commits `40b08f3f` on v0.4.0 and `38e6f165` on main, local).

Tuning on the dev half chose weight 3.0 under the preregistered rule (English
dev term recall 63% to 85%; frozen FLEURS English WER +0.05 pp; Russian
unchanged). Weight 4.0 reached 90% English recall but raised FLEURS English WER
by 0.37 pp.

Gate result at weight 3.0, through the app's adapter:

- Rule 1 passed: pooled term recall on the test half 31.0% to 47.9%; English
  22/37 to 32/37, Russian 0/34 to 2/34.
- Rule 2 failed: pooled FLEURS WER +0.071 pp, 95% interval +0.010 to +0.137,
  above the +0.10 limit (English 27 utterances worse, 13 better).
- Rule 3 passed: with no terms, all 1,422 FLEURS transcripts are identical to
  upstream 0.4.0.
- Rule 4 failed: 18 invented words on the noise clips, among them
  "Postgres." on two seconds of digital silence.

Decision: not adopted. The bonus on a term's first token could outscore blank,
so biasing changed whether the decoder emitted anything. Russian speech that
says English terms the Russian way barely moved, so for Russian the text
dictionary stays the tool.

## H4b. Phrase boosting that only re-ranks emitted tokens

Preregistered on branch `claude/term-biasing` before any code existed. The
model's own argmax decides between blank and a token; only an emitted token is
re-ranked by the vocabulary. Tuning picked weight 3.0.

Gate result: rule 1 passed (test-half recall 31.0% to 47.9%; English 22/37 to
32/37, Russian 0/34 to 2/34), rule 2 passed narrowly (pooled FLEURS WER +0.044
pp, 95% interval −0.007 to +0.097), rule 4 passed (no invented words, wrong
script unchanged). Rule 3 holds because the no-terms path is the same code as
H4c's, which was measured identical. Rule 5 (speed) is pending.

## H4c. No bonus on a term's first piece

Preregistered before H4b's gate ran. On top of H4b, a term earns its bonus only
after the model has begun it. Every tuning weight left frozen FLEURS WER
exactly unchanged; the rule picked weight 8.0 for the highest dev recall.

Gate result: rule 1 passed (31.0% to 43.7%; English 22/37 to 31/37, Russian
0/34 to 0/34), rule 2 passed (+0.047 pp, interval +0.014 to +0.091), rule 3
passed (all 1,422 FLEURS transcripts identical to upstream 0.4.0 without
terms), rule 4 passed. Rule 5 is pending.

### Choosing between H4b and H4c

Both variants pass rules 1 to 4, and no rule was written in advance for
choosing between two passing variants. H4b is marginally ahead on both
averages: three more terms found and 0.003 percentage points less WER. The
decision below was made after seeing the results, for this reason: H4b changed
62 FLEURS utterances, mostly ordinary names rewritten ("christina" to
"cristina", "brides" to "hrides"), while H4c changed 16, every one toward a
vocabulary term ("sintra" to "sentry", "features" to "feature"). Errors on
names the person did not ask for are the failure the plan ranks worst, and an
error toward a term the person taught is predictable and visible.

Rule 5, in an interleaved warm run of the same runtime with and without the 60
terms: p50 327.8 against 326.3 ms idle (+0.5%) and 428.1 against 421.9 ms under
load (+1.5%), within the 5% limit.

Decision: H4c passes all five rules and is adopted, pending a runtime build
that ships it (a fork release or an upstream merge, both of which need Mik's
approval). H4b stays recorded as passing rules 1 to 4.
Russian speech that says English terms the Russian way is not helped by either
variant, so for Russian the text dictionary stays the tool.

## H6. Where the engine's time goes

Measurement only, no decision. The transcribe.cpp CLI reports mel, encoder
and decoder milliseconds per input; `profile.py` collects them for the six
speed inputs and the six long takes on a quiet Mac. The tuning runs already
show the decoder at about 43 ms per frozen FLEURS file against roughly 115 ms
of engine time, so the decoder is about 38% of the engine and the mel front
end plus the Metal encoder the rest.

Result (`profile-v3-0.4.0.json`, `profile-ultra-0.4.0.json`; one CLI process,
one decoder thread, Metal, medians of six runs on a quiet Mac). The mel front
end is under 2 ms. The encoder grows roughly linearly at about 7 ms per second
of audio: 37 to 50 ms for 4.5 s, 61 to 73 ms for 9 to 11 s, 135 to 170 ms for
23 to 29 s, and about 1 s for a two-minute take decoded in one pass. The
decoder takes about 3 to 4 ms per second of audio: 17 to 22 ms for 4.5 s and
93 to 117 ms for 23 to 29 s. For a typical dictation of 5 to 10 s the encoder
is about 60% of the engine and the decoder about 40%. Ultra's split is the
same.

## H8. The joint network's output layer in the model's own precision

Preregistered on 20 October 2026, before any code for it existed.

The Parakeet decoder runs on one CPU thread. On every step it multiplies the
joint hidden state by the output layer, 8,198 by 640 weights, and the runtime
dequantizes that layer from the file's Q8_0 to F32 at load, so every step
reads about 21 MB from memory. Q8_0 is about 5.6 MB and fits in the
performance cores' L2 cache; F16 is about 10.5 MB.

Variants: H8a keeps the layer in Q8_0, H8b converts it to F16. Both run
through ggml's own CPU kernels; the predictor and every other weight stay as
they are. A variant is adopted when all of these hold against the unchanged
runtime, with the same model (v3 Q8) and one decoder thread:

1. Median decoder time per frozen FLEURS file, from the runtime's own timing
   on a quiet Mac, falls by at least 30%.
2. On all 1,422 FLEURS utterances the upper end of the 95% paired interval
   for the pooled WER difference is at most +0.05 percentage points, and at
   least 97% of transcripts are identical.
3. No word is invented on the noise clips, the wrong-script count does not
   rise, and hour-file deleted-word rates rise by at most 0.2 percentage
   points.
4. Warm p50 and p95 in an interleaved speed run do not get worse.

If both variants pass, the faster one is adopted; on a tie, the one closer to
the unchanged transcripts. The result is recorded here either way.

## H10. Four threads on the CPU backend (Windows, Linux, Intel Mac)

Preregistered on 20 October 2026 before measurement. The desktop app always
gives the recognition session one thread (`core/ramble-engine/src/lib.rs`).
That is right on an accelerator, where the session threads only run the
decoder and two or more threads add a spin barrier that collapses under load.
On the CPU backend the same threads also run the encoder; an audit measured a
12-second clip at 2.6 to 3.0 s with one thread and 0.83 to 1.10 s with four.

The change gives the CPU backend `min(4, available cores)` threads and keeps
one thread on Metal and Vulkan. It is adopted when, with transcribe.cpp on the
CPU backend and Parakeet v3 Q8, on the six speed inputs, interleaved, at least
six times each per condition:

1. Idle, the four-thread median whole-run time is at most 0.67 times the
   one-thread median.
2. Under the 14-process CPU load, the four-thread median is not slower than
   the one-thread median.
3. Transcripts are identical between one and four threads.
4. The `ramble-engine` unit tests, the conformance test and
   `transcribes_real_speech` pass unchanged.

## H11. A smaller quantization of the chosen model

Preregistered on 20 October 2026 before any output of these files existed.
Parakeet Ultra is also published as Q5_K_M (550 MB) and Q4_K_M (486 MB). A
smaller file is a faster first run and less disk for every person. A smaller
quantization replaces Q8_0 (740 MB) when, against Ultra Q8_0 on runtime 0.4.0:

1. On all 1,422 FLEURS utterances, the upper end of the 95% paired interval
   for the pooled WER difference is at most +0.20 percentage points.
2. No word is invented on the noise clips, the wrong-script count does not
   rise, and hour-file deleted-word rates rise by at most 0.2 points.
3. Warm p95 is not more than 5% slower in an interleaved speed run.

If both pass, the smaller file is chosen.

## H13. Ultra Q4_K_M on the CPU backend (Windows and Linux)

Preregistered on 20 October 2026 before this measurement. The desktop app for
Windows and Linux compiles in the same `model-manifest.json` as the Mac, so
switching the Mac to Ultra Q4_K_M switches the desktop app too. The desktop
app runs on the CPU backend with one session thread, where every speed number
above (all on Metal) says nothing. No desktop build has shipped yet, so there
is no installed v3 to migrate.

Ultra Q4_K_M replaces v3 Q8_0 on the desktop app when, with transcribe.cpp
0.4.0 on the CPU backend, one thread, the six speed inputs, in 12 blocks that
alternate quiet and the 14-process load in ABBA order and alternate the model
order within them:

1. Idle, Ultra's median per-input time (mel + encode + decode) is at most 1.10
   times v3's.
2. Under load, the same ratio is at most 1.10.

If either fails, the desktop app keeps v3 through its own manifest, and the
Mac switches alone.

## H13b. Ultra Q8_0 on the CPU backend

Preregistered on 20 October 2026 after the H13 result and before this
measurement. Ultra and v3 share the architecture, so H13's slowdown should come
from the Q4_K_M quantization, not the model. Ultra Q8_0 (740 MB, the file the
bake-off scored) replaces v3 Q8_0 on the desktop app under the same two rules
as H13: Ultra's median per-input time on the CPU backend is at most 1.10 times
v3's, idle and under load, in the same 12-block design.

If it passes, the desktop app ships Ultra Q8_0 from its own manifest while the
Mac ships Q4_K_M. If it fails, the desktop app keeps v3.

## H15. Weights served from the model file (upstream main after #195)

Preregistered on 20 October 2026 before any output of this runtime existed on
this Mac. This is ranked improvement 4e in the plan. transcribe.cpp 0.4.0 copies
every weight into memory the process owns. Upstream #195, merged after 0.4.0,
memory-maps the GGUF file instead and hands the mapped pages to the primary
device when it can use host memory, which includes Metal on Apple silicon.
Mapped weights are clean, file-backed pages: macOS can reclaim them under
memory pressure instead of charging them to the app, and the app and the CLI
loading the same file can share them. Upstream main also carries #199 (Parakeet
long-form memory) and other changes since 0.4.0, so this is a whole-runtime
comparison like H1, not a test of #195 alone.

The candidate is transcribe.cpp built from upstream main at `db678a03` by
`scripts/build-transcribe-xcframework.sh`. The baseline is 0.4.0. Both run
Parakeet Ultra Q4_K_M, the model #79 ships, through the app's adapter. The
footprint is the process's physical footprint (`task_vm_info.phys_footprint`,
what Activity Monitor shows), which `asr-bench serve` now reports; peak RSS
cannot show this change because mapped pages count toward it.

The runtime is adopted when:

1. At least 99% of the 1,422 FLEURS transcripts are identical, and the pooled
   WER difference is within ±0.10 points.
2. Wrong-script decodes and invented words are not more than with 0.4.0.
3. Hour-file deleted-word rates are within 0.2 points.
4. Warm p50 and p95 are within 5% + 2 ms, idle and under load, and the whole-process
   p50 is within 10%, in an interleaved run.
5. The footprint after load and warm-up is at least 300 MB lower, and the peak
   footprint over the warm run is not higher.
6. The model load with a warm file cache is not more than 10% slower.
7. No new unit or end-to-end test failure, and the binary audit passes.
8. No code path in the app, the CLI or the desktop store rewrites an installed
   model file in place. A mapped file changed in place kills the process
   (SIGBUS), so this is checked by reading every writer of the model
   directory.

A cold page cache needs `sudo purge` and is not measured; a first dictation
after the OS has evicted the pages reads them from disk, and that cost is
reported as a limit, not gated.

## H15b. Upstream main with the model #79 ships

Preregistered on 20 October 2026 after the H15 result. H15 failed only rule 7,
and the cause is upstream #199, not the memory mapping: since #199,
transcribe.cpp runs full-attention Parakeet checkpoints, v3 among them, with
`[256,256]` local attention on clips longer than 20.5 s, so v3's long-input
transcripts change. Ultra's transcripts did not change in any H15 suite.

The same runtime (`db678a03`) is adopted together with #79 when:

1. Rules 1 to 6 and 8 of H15 hold for Ultra Q4_K_M. They were measured in H15
   and are not run again.
2. On the #79 branch, whose bundled manifest is Ultra Q4_K_M, the LocalASR
   unit and end-to-end suites with Ultra installed have no failure under
   `main` that they do not have under 0.4.0.
3. v3 serves people only until their Ultra download verifies. Its long-input
   change under `main` is not gated, because it is NVIDIA's documented
   long-audio mode and upstream measured it better on v3's English mid-length
   speech (TED 3.19 to 2.35% WER) and worse on French. It is stated in the
   #79 pull request instead.

## H16. transcribe.cpp 0.4.1, and the app runs it

Preregistered on 27 October 2026, before any output of 0.4.1, or of the
runtime the app itself has been running, existed on this Mac.

H1 adopted 0.4.0 and H15b adopted upstream main at `db678a03`, both measured
through `asr-bench`, which calls the pinned CTranscribe framework. The app did
not call it. `RambleCoreFFI` linked the Rust crate `transcribe-cpp-sys` 0.2.0
statically, and that copy answered every call the adapter made (found by PR
#87; `dyld_info -imports` on shipping 0.33.1 shows only two Whisper helpers
taken from the framework). So 0.33.1 and 0.34.0 run Parakeet Ultra Q4_K_M on
transcribe.cpp 0.2.0, which predates Ultra support (upstream #192, in 0.4.0):
it ignores the checkpoint's `length_masking = "kestrel"`, its global symbol
budget and its pause segmenter. No suite has measured that configuration.

The change pins 0.4.1, the first release that contains `db678a03`, removes
`ramble-engine` from `ramble-ffi` so the app calls the framework, and moves the
Rust crates to 0.4.1. The candidates:

- `app-0.34.0`: `asr-bench` at the 0.34.0 release commit `6b2e56a` with that
  commit's `libramble_ffi.a` force-loaded, so every `transcribe_*` call lands in the cargo-built 0.2.0
  copy, as in the app. Checked with `dyld_info -imports` before it runs.
- `runtime-0.4.1`: `asr-bench` at this change, on the pinned 0.4.1 framework.
- `runtime-main-ultra-q4km`: H15's committed observations.

0.4.1 is the build H15b adopted when:

1. All 1,422 FLEURS transcripts, the six long takes and the five hour-file
   transcripts are identical to `runtime-main-ultra-q4km`. If not, H15's rules
   1 to 6 run again against 0.4.0 before anything else.

What changes for people, `app-0.34.0` against `runtime-0.4.1`, all in one
interleaved run:

2. Pooled FLEURS WER is not higher by more than 0.10 points, and neither
   language by more than 0.25 points (paired bootstrap interval reported).
3. Wrong-script decodes and invented words are not more.
4. Hour-file deleted-word rates are within 0.2 points or lower.
5. Warm p50 and p95 are within 5% + 2 ms, idle and under load; whole-process
   p50 within 10%.
6. The footprint after load and warm-up is at least 300 MB lower, and the peak
   footprint over the warm run is not higher.
7. The stress lab (`scripts/stress-lab.sh`, all five conditions, builds
   alternating first) lands every take and misses no more words in total.
   Its latencies are reported, not gated per row: the shared Mac's load swings
   from 6 to over 100 between adjacent runs. A condition counts as a
   regression only if release-to-paste p50 and p95 are both more than 30%
   worse for both take lengths.
8. `check.sh` is green; the LocalASR unit and end-to-end suites, with Ultra
   installed in a separate models root, have no failure that main lacks; the
   new binding test in `OpenRambleTests` fails on main and passes here.

The Linux server, Ultra Q4_K_M on the CPU backend in an arm64 container,
0.2.0 against 0.4.1 on a public hour file:

9. WER against the reference is not higher by more than 0.25 points.
10. `serve` with four engines peaks lower in memory, and file mode with four
    workers is not more than 10% slower.

If a rule fails, the change is not merged and the failure is recorded here.

## H16b. No engine input longer than 30 seconds

Preregistered on 27 October 2026 after the H16 result below, before any
output of the change existed.

H16 failed rule 4 alone, and the cause is in transcribe.cpp 0.4.x, not in the
app: Parakeet Ultra cuts any run longer than 30 s with its own pause
segmenter, keeps a piece only if its speech head finds speech in it, and on a
piece that begins mid-sentence the head can find none. The file chunker gives
the engine up to 34 s (a 30 s segment, 2 s of context on each side, and a final
tail under 2 s merged in), so file import and long dictation takes reach that
path; 0.2.0 had no segmenter and never did.

The change caps a chunk's segment at 25 s, so no engine input exceeds 30 s.
(Preregistered first as 26 s; corrected before any output, because the cap is
checked once per 20 ms frame and 26 + 4 s of context and tail can reach
30.02 s.)
Against `app-0.34.0`, with `runtime-0.4.1` at the new commit, it is adopted
together with H16 when:

1. Hour-file deleted-word rates are within 0.2 points of `app-0.34.0` or lower,
   and no hour file's WER is higher by more than 0.25 points.
2. No long take has a run of five or more deleted words.
3. A unit test shows that no chunk of continuous audio, a merged tail
   included, exceeds 30 s.
4. The LocalASR unit and end-to-end suites, the opt-in long-dictation gate
   included, have no failure that H16's run lacked.

FLEURS is not run again: every FLEURS file is shorter than 30 s and is
decoded whole, so the change cannot reach it.

## H16c. Long files without losing words

Preregistered on 27 October 2026, before any output of these candidates
existed.

The 30 s cap of H16b keeps transcribe.cpp 0.4.x away from Parakeet Ultra's
own pause segmenter and costs long English and mixed files 0.5 to 2 points.
The segmenter's fault is now known (upstream issue #235): it scores speech
over a whole 120 s block on features normalized over that block, so speech
about 40 dB quieter than a neighbour scores as silence and its piece is
dropped. The fork `mikwiseman/transcribe.cpp`, branch `openramble/v0.4.1`
(`c4cd60da`), scans such a piece again on its own before dropping it; the
33.13 s repro gives 73 words with it and 40 without, on Metal and CPU.

Candidates, file import and long dictation through the app's chunker:

- `fork-chunks30`: the fork, 30 s segments with 2 s of context (up to 34 s,
  the chunking 0.34.0 shipped), so the fixed segmenter handles the excess.
- `fork-chunks60`: the fork, 60 s segments, so Ultra segments the audio
  itself.
- `runtime-0.4.1-chunks27`: 0.4.1 as released, 27 s segments with 1 s of
  context, every input at or under 30 s.

References: `app-0.34.0` (what 0.34.0 shipped) and `runtime-0.4.1-chunks25`
(what 0.35.0 ships).

A candidate qualifies when:

1. No lost words: on each hour file and long take, the reference words in
   deleted runs of three or more are no more than under `app-0.34.0`. (That
   is zero on the English and Russian hour files and on every take.)
2. For the fork, all 1,422 FLEURS transcripts are identical to
   `runtime-0.4.1`: inputs of 30 s or less never reach the change.
3. File-import wall time over the five hour files is at most 10% above
   `runtime-0.4.1-chunks25`.

Among qualifying candidates, the one with the lowest word-weighted WER over
the five hour files and six takes is shipped, if that WER is below
`runtime-0.4.1-chunks25`'s. Every file is also reported against `app-0.34.0`.

## H16d. Seams without overlap

Preregistered on 27 October 2026 after the H16c result, before any output of
these candidates existed.

Every word H16c still lost sat at a seam where the app joins two overlapping
file chunks by word time. With no overlap there is nothing to match: each
chunk is exactly its segment, a word belongs to the chunk its middle falls
in, and no tail is merged. The Linux server works this way.

Candidates, file import and long dictation, overlap 0:

- `fork-chunks30-seam0`: the fork (`c4cd60da`), 30 s segments. A forced cut
  can pass 30 s by one 20 ms frame; the fixed segmenter takes that.
- `fork-chunks60-seam0`: the fork, 60 s segments; Ultra segments within.
- `runtime-0.4.1-chunks29-seam0`: released 0.4.1, 29 s segments, every input
  under 30 s, no fork needed.

A candidate qualifies when:

1. No lost words (reference words in deleted runs of three or more) on the
   English and Russian hour files and on every take, and on each mixed file
   no more than 5% above `app-0.34.0`'s. (Across H16c's setups the mixed
   files' losses moved by up to 75 words of about 2,200 with no change in
   the seams, since the model drops one of the two languages.)
2. For a fork candidate, FLEURS is identical to `runtime-0.4.1` (already
   shown in H16c for this commit).
3. File-import wall time over the five hour files at most 10% above
   `runtime-0.4.1-chunks25`.

Among qualifying candidates, the lowest word-weighted WER over the five hour
files and six takes ships, if it is below `runtime-0.4.1-chunks25`'s; with
released 0.4.1 and the fork within 0.1 point of each other, the one without
the fork ships.

## Live text needs partials at least every 300 ms

Recorded on 20 October 2026 as a gate for any future live-text feature, not
measured yet. Partial text must update at least every 300 ms while the person
speaks, and final text must still pass every gate above. Nemotron 3.5, the
only streaming candidate, failed the accuracy rule, so no current candidate
can offer live text. The whole-product audit also found that only 46 of 90
long takes produced any streamed segment with today's pause-based segmenter,
which is a separate question about the app's segmenter, owned outside this
program.

### H8 result

Measured on the frozen 200 FLEURS files with one build whose joint weight type
is chosen at run time (`profile-joint-*.json`, `v3-joint-*` candidates). The
median decoder time per file is 40.4 ms in F32, 30.0 ms in the model's Q8_0
(−26%) and 32.3 ms in F16 (−20%); the encoder is unchanged at 64 ms. Accuracy
holds: against F32, Q8_0 changes 11 of 1,422 FLEURS transcripts with a pooled
WER difference of −0.013 pp (95% interval −0.034 to +0.003), F16 changes one
(−0.003 pp), neither invents words, and the wrong-script count is unchanged.
The F32 control is identical to upstream 0.4.0 on all 1,422 utterances.

Decision: not adopted. Both variants miss rule 1, a 30% decoder reduction.
Q8_0 saves about 10 ms on a 10-second take at no measured accuracy cost; it is
a candidate to combine with the predictor's own weights (H8c, below) and
measure again.

## H10 result

Measured with transcribe.cpp 0.4.0 on the CPU backend, v3 Q8, the six speed
inputs, 12 alternating blocks (`cpu-threads.json`). Median per input: idle,
1,249 ms with one thread and 346 ms with four (3.6 times faster); under the
14-process load, 1,912 ms with one thread and 3,578 ms with four (1.9 times
slower). Transcripts are identical.

Decision: not adopted. Rule 2 fails: under load, four threads lose to one by
almost a factor of two, for the same spin-barrier reason the Mac pins one
decoder thread. The change was reverted. The next hypothesis is to split the
two: four threads for the encoder and one for the decoder (H10b), which needs
a runtime parameter for decoder threads.

## H11 result

Against Ultra Q8_0 on all 1,422 FLEURS utterances: Q5_K_M (550 MB) pooled WER
−0.007 pp (95% interval −0.087 to +0.072); Q4_K_M (486 MB) +0.071 pp (−0.040
to +0.183), English −0.06 and Russian +0.19 pp. Neither invents a word or
writes the wrong alphabet, hour-file deletions stay within 0.2 points (Q4_K_M:
English 2.71% against 2.97%, Russian 0.85% against 0.79%), and in an
interleaved warm run their p95 stays within 3% of Q8_0 in every bucket.

Decision: both pass; under the rule the smaller file is chosen, so the
recommended download is Parakeet Ultra Q4_K_M, 486 MB instead of 740 MB.

## H13 result

Measured with transcribe.cpp 0.4.0 on the CPU backend, one thread, the six
speed inputs, 12 alternating blocks (`cpu-models.json`). Median per input:
idle, v3 Q8_0 1,327 ms and Ultra Q4_K_M 1,705 ms (1.29 times); under the
14-process load, 2,305 ms and 2,998 ms (1.30 times). Every one of the six
inputs is 1.2 to 1.4 times slower with Ultra Q4_K_M in both conditions. Three
samples in block 6 took 213 to 1,451 seconds, which fits the Mac sleeping
during that block; the medians are unaffected by them.

Decision: both rules fail, so Ultra Q4_K_M does not go to the desktop app.
H13b asks whether the quantization is the cause.

## H13b result

Same design, Ultra Q8_0 against v3 Q8_0 (`cpu-models-q8.json`). Median per
input: idle, 1,276 ms for v3 and 1,305 ms for Ultra (1.02 times); under load,
2,100 ms and 2,164 ms (1.03 times). Per input the ratio is 1.00 to 1.04 idle
and 0.89 to 1.07 under load, with no outliers.

Decision: both rules pass. The slowdown in H13 comes from the Q4_K_M
quantization on the CPU backend, not from Ultra. The desktop app ships Ultra
Q8_0 (740 MB) from its own manifest, and the Mac ships Q4_K_M (486 MB).

Intel Macs also run the Mac app on the CPU backend, so they get Q4_K_M with
the same likely cost. That was not measured on an Intel CPU, and it is listed
below as an open question rather than decided here.

## H15 result

Measured with Ultra Q4_K_M on transcribe.cpp 0.4.0 and on upstream main at
`db678a03` (`h15.json`; speed, load and memory from an interleaved run tagged
`h15`):

| Rule | 0.4.0 | main | Verdict |
|---|---:|---:|---|
| 1. FLEURS transcripts identical; pooled WER | | 1,422 of 1,422; +0.00 pp | pass |
| 2. Wrong script / invented words | 0 / 0 | 0 / 0 | pass |
| 3. Hour-file deleted words, English / Russian | 2.71% / 0.85% | the same; all 5 hour transcripts identical | pass |
| 4. Warm p50 / p95 idle | 366 / 1,732 ms | 346 / 1,701 ms | pass |
| 4. Warm p50 / p95 under load | 406 / 2,032 ms | 394 / 2,019 ms | pass |
| 4. Whole-process p50 idle | 0.402 s | 0.291 s | pass |
| 5. Footprint after load / peak | 753 / 842 MB | 269 / 352 MB | pass |
| 6. Model load, warm file cache | 0.191 s | 0.106 s | pass |
| 7. Unit / end-to-end tests | 163 run, 7 skipped, 0 failed / 21 run, 3 skipped, 0 failed | the same unit result / 2 end-to-end tests fail | **fail** |
| 7. Binary audit | | passes | |
| 8. No in-place rewrite of a model file | | holds; all writers use staging and directory renames | pass |

Rule 7's two failures are in `FileQualityTests`, which run the installed model,
v3 on this Mac. They assert that the app's chunked file path is never worse
than one whole-file pass. Under main the whole-file pass improved (455-word
file: 22 errors to 13; mixed file: 39 to 33) while the chunked path stayed the
same or improved (19/20/16 to 19/15/13 at 15/30/60 s chunks), so the
comparison now fails. The mixed file also writes "Мари Иванова" for "Мария
Иванова" twice, where 0.4.0 wrote it right. The cause is #199: since it,
full-attention checkpoints such as v3 run local attention on clips longer
than 20.5 s, which changes v3's long-input output. Ultra's output did not
change anywhere in H15.

Not gated: the English hour file took 52.3 s on main against 46.5 s on 0.4.0,
and the Russian one 47.5 against 45.7 s, each from a single run that was not
interleaved. A first recognition after the OS evicts the mapped pages reads
them from disk again; that was not measured (it needs `sudo purge`).

Decision: under the preregistered rules H15 fails and main is not adopted as
measured. H15b asks the narrower question with the model #79 ships.

## H15b result

On the #79 branch with Ultra Q4_K_M installed in a separate models root and
imported through the app's own checksum-verified path, the LocalASR suites
give the same result under 0.4.0 and under main: unit 171 run, 7 skipped, 0
failed; end-to-end 21 run, 3 skipped, and the same three tests failing (five
assertions) under both runtimes. Rule 2 holds, so main is adopted together
with #79. Pinning it needs a published binary: an upstream release that
contains `db678a03`, or the audited build of it published from the
`mikwiseman/transcribe.cpp` fork.

## Ultra on the end-to-end suite

H15b ran the end-to-end suite with Ultra for the first time; until then it had
only run with v3, because it uses the model installed for the app. Three tests
fail with Ultra under either runtime, all on macOS synthetic voices:

- `testEnglishTrailingSendStaysVerbatimAndNeverPressesReturn`: the take ends
  in "send it", and Ultra writes "Please review my pull requests and it." The
  planned "Send it." command depends on these words arriving.
- `testChunkProfilesPreserveRepeatedSpeechAndTheFinalWords`: at the shipping
  30 s split the chunked file has 16 errors against 15 for one whole-file
  pass (455 words). The 15 s and 60 s splits have 13.
- `testStarterDictionaryOnRealModelOutput`: three developer terms said the
  Russian way come out in spellings the starter dictionary does not map:
  "фичерфлэг" for feature flag, and "Rebace" and "Mordge" for rebase and
  merge. The dictionary was built from v3's spellings.

#79 resolves them as follows. The starter dictionary learns the three
spellings as exact post-processing rules, with a test on the Swift side and on
the Rust side and the regenerated fixture the Rust port reads; the conformance
corpus output does not change. The other two stay recorded as strict expected
failures: the test's main promise, that speech never presses Return, still
holds, and a model that hears the words again, or closes the one-word gap at
the 30 s split, turns them red. The 15 s and 60 s splits beat whole-file
decoding for both models here, so moving the file split is a candidate
hypothesis of its own (it needs the hour files measured at the new split).

## H16 result

Measured on 27 October 2026 with the scorecard (`app-0.34.0`,
`runtime-0.4.1`), the stress lab (`research/stress-lab-2026-10/data/h16`) and
the LocalASR suites. Before any run, `dyld_info -imports` confirmed the
bindings: the `app-0.34.0` asr-bench takes no `transcribe_*` symbol from the
framework (the force-load also brings in the two Whisper helpers the app takes
from it, which Parakeet never calls), the 0.34.0 test bundle defines
`transcribe_run` itself, and the #92 app, CLI and test bundle take all 20
functions from CTranscribe 0.4.1. The new binding test fails on the 0.34.0
build ("the runtime is the OpenRambleTests binary itself") and passes on #92.

| Rule | 0.34.0 as shipped (0.2.0) | #92 (0.4.1) | Verdict |
|---|---:|---:|---|
| 1. Identical to H15's `db678a03` | | 1,422 FLEURS, 200 FLEURS, 11 noise, 6 takes, 5 hour: all identical (`h16-transcripts.json`) | pass |
| 2. Pooled FLEURS WER | 5.31% | 4.85%; −0.46 pp (95% interval −0.59 to −0.35), 95 utterances better, 6 worse | pass |
| 2. English / Russian | 5.06% / 5.54% | 4.86% / 4.84% (−0.21 and −0.71 pp, both intervals below zero) | pass |
| 3. Wrong script / invented words | 0 / 0 | 0 / 0 | pass |
| 4. Hour-file deleted words, English / Russian | 0.88% / 0.85% | 2.71% / 0.85% | **fail** |
| 5. Warm p50 / p95, all inputs, idle | 427 / 1,939 ms | 332 / 1,648 ms | pass |
| 5. Warm p50 / p95, under load | 618 / 2,827 ms | 405 / 1,964 ms | pass |
| 5. Whole-process p50, idle / load | 0.424 / 0.679 s | 0.264 / 0.348 s | pass |
| 6. Footprint after load / peak | 739 / 1,110 MB | 267 / 366 MB | pass |
| 7. Stress lab: landed, words missed | 51 of 51, 0 | 51 of 51, 0; release → paste faster at the median in every condition | pass |
| 8. check.sh, LocalASR unit and end-to-end, binding test | | all green; 22 end-to-end run, 3 opt-in skipped, the same as 0.34.0 | pass |

Model load fell from 0.156 to 0.066 s. The opt-in long-dictation gate (4 to 15
minutes, Russian and English) gives identical WER under 0.4.0 and 0.4.1 with
peak memory 788–824 MB against 545 MB, and stop-to-insertion p50 / p95 of 123 /
143 ms against 128 / 133 ms.

Rule 4's failure is 142 English words, two whole sentences each of the three
times the composite repeats them. The file importer's chunks run up to 34 s,
and transcribe.cpp 0.4.x hands any Parakeet Ultra input over 30 s to its own
pause segmenter (`stt.parakeet.segmenter.max_segment_seconds = 30` in the
GGUF), which keeps a piece only if its speech head finds speech there. On the
chunk at 991.21 s of `en-3540s` (33.13 s, beginning mid-sentence) it kept one
piece, 12.4 to 33.13 s, and dropped the first 12.4 s: 73 words on 0.2.0, 40
on 0.4.1. The same audio cut to 30.0 s gives 67 words on 0.4.1, and no 30 s
window in the region loses a run of words on 0.4.1. The six long dictation
takes (33 to 129 s) lost nothing on 0.4.1. The server's pieces are at most
20 s and never reach the segmenter. H16 is not adopted as measured; H16b asks
whether keeping every input at or under 30 s removes the loss.

## H16b result

Measured the same day: `runtime-0.4.1-chunks25` (#92 with 25 s chunks), and as
a control `app-0.34.0-chunks25`, 0.34.0's own 0.2.0 runtime with only the chunk
cap changed (a local commit, `dcc6aea`; not indexed). WER and deleted-word
rate in percent, hour files and long takes:

| Input | 0.2.0, 30 s (shipping) | 0.2.0, 25 s | 0.4.1, 30 s | 0.4.1, 25 s |
|---|---:|---:|---:|---:|
| English hour | 5.34 / 0.88 | 5.70 / 1.25 | 7.27 / 2.71 | 5.86 / 1.41 |
| Russian hour | 6.40 / 0.85 | 6.19 / 0.85 | 5.58 / 0.85 | 5.49 / 0.85 |
| Mixed 600 s | 31.63 / 26.60 | 34.66 / 30.16 | 31.37 / 27.64 | 33.71 / 30.33 |
| Mixed hour | 39.43 / 34.46 | 40.00 / 35.40 | 37.99 / 33.72 | 39.44 / 35.53 |
| English take, 60 s | 4.94 | 6.17 | 5.56 | 6.17 |
| English take, 120 s | 2.97 | 3.96 | 3.63 | 3.96 |
| Russian take, 120 s | 9.39 | 8.29 | 7.18 | 6.63 |

| Rule | Result | Verdict |
|---|---|---|
| 1. Hour files against shipping | English +0.52 pp WER, +0.53 pp deleted; mixed 600 s +2.08 pp; mixed hour +1.07 pp deleted | **fail** |
| 2. No deleted run of five words in a take | longest run 1 word | pass |
| 3. No chunk over 30 s | `FileAudioChunksTests` and the routing test (240–900 s, memory and file paths) | pass |
| 4. No new suite failure | LocalASR unit 176 run, 9 skipped, 0 failed; the chunk-profile test makes 13 errors at 25 s against 15 whole-file, so its strict expected failure became a plain assertion | pass |

The control separates the two causes. At equal chunks 0.4.1 matches or beats
0.2.0 on every input (English hour +0.16 pp, everything else lower), so the
runtime is not what costs accuracy. The 25 s chunks are: they cost about as
much on 0.2.0. With 0.4.x, 30 s of input is the most that avoids Ultra's own
segmenter, so the 34 s inputs 0.34.0 decodes with 0.2.0 are not available.

The longest deleted run in the English hour file falls from 29 words at 30 s
to 6 at 25 s. Nothing is silently dropped anymore.

Decision (Mik, 27 October 2026): H16 is adopted with H16b's 30 s cap,
although both failed the hour-file rule. The runtime is not the cause at equal
chunks, everything else improves, and the alternative kept the app on a
runtime that predates its model. H16c is to win the long-file accuracy back.

## H16c result

Measured on 27 October 2026 (`fork-chunks30`, `fork-chunks60`,
`runtime-0.4.1-chunks27`; candidate commits are local, `dbb5d4a`, `2b1d529`,
`6aff0cb`). WER in percent, and lost words: reference words in deleted runs
of three or more.

| Input | 0.34.0 shipped | 0.35.0 shipped | fork, 30 s | fork, 60 s | 0.4.1, 27 s + 1 s |
|---|---:|---:|---:|---:|---:|
| English hour | 5.34 / 0 | 5.86 / 30 | 6.23 / 48 | 5.80 / 0 | 5.91 / 31 |
| Russian hour | 6.40 / 0 | 5.49 / 0 | 5.58 / 0 | 5.42 / 0 | 5.93 / 0 |
| Mixed 60 s | 19.12 / 22 | 18.38 / 22 | 18.38 / 22 | 18.38 / 22 | 19.12 / 23 |
| Mixed 600 s | 31.63 / 293 | 33.71 / 337 | 31.37 / 306 | 33.36 / 333 | 31.20 / 303 |
| Mixed hour | 39.43 / 2,227 | 39.44 / 2,302 | 37.99 / 2,180 | 38.69 / 2,234 | 35.40 / 1,948 |
| English take, 37 s | 6.58 / 0 | 6.58 / 0 | 6.58 / 0 | 6.58 / 0 | 14.47 / 7 |
| English take, 72 s | 4.94 / 0 | 6.17 / 0 | 5.56 / 0 | 4.94 / 0 | 3.70 / 0 |
| English take, 129 s | 2.97 / 0 | 3.96 / 0 | 3.63 / 0 | 4.62 / 0 | 3.63 / 0 |
| Russian takes, 33 / 72 / 120 s | 1.79 / 6.78 / 9.39 | 0 / 6.78 / 6.63 | 0 / 6.78 / 7.18 | 0 / 6.78 / 6.08 | 1.79 / 8.47 / 7.73 |
| Pooled WER, hour files and takes | 17.22 | 17.26 | 16.86 | 16.98 | 16.09 |
| File-import wall time, five hours | 176.7 s | 149.4 s | 157.4 s | 151.9 s | 134.9 s |

Rule 2 holds for the fork: all 1,422 FLEURS transcripts are identical to
`runtime-0.4.1`. Rule 3 holds for every candidate (load averaged 6 to 28 during
the runs). Rule 1 fails for every candidate, so none is shipped:

- `fork-chunks60` loses no word on any English or Russian input or take, but
  loses 7 and 40 more words than 0.34.0 on the two long mixed files, where
  every setup loses about two thousand words of the minority language.
- `fork-chunks30` still loses one 16-word sentence each time it recurs in the
  English hour file. The fix recovered the 29-word loss, not this one.
- `runtime-0.4.1-chunks27` loses 7 and 8 words in a row at chunk seams and 7
  words of the 37 s English take.

The lost runs that remain all sit where two of the app's overlapping chunks
are joined, and 0.34.0 on 0.2.0 lost none there. Ultra's segmenter is not
the only fault: joining overlapping chunks by word times loses words on
0.4.x. The Linux server cuts at its quietest points without overlap and
joins nothing, and its English hour-file WER on 0.4.1 was 5.57% (H16 rule 9).

## Proposed next hypotheses

- **H8c.** The decoder's joint output layer and LSTM weights in the model's
  Q8_0 together, against the same 30% decoder rule.
- **H10b.** Four encoder threads and one decoder thread on the CPU backend.
- **H14.** Intel Macs: Ultra Q4_K_M against Q8_0 on an Intel CPU. If Q4_K_M is
  as slow there as on the Apple CPU backend (H13), Intel Macs take Q8_0.
- **H12.** The encoder is now the larger share. Test a cached encoder graph
  per input length (the runtime rebuilds and re-allocates the graph on every
  run) as the cheap step, then an ANE encoder only with a never-slower gate,
  cold and warm, and an automatic Metal fallback.
