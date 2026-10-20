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
