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
- Speed and memory: pending the interleaved speed run.

Decision: pending rules 4 and 5.

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

Decision: pending gates 5 and 6 (speed and memory) for Ultra.

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
re-ranked by the vocabulary. Same gate, weight grid 1 to 8, and a weight is
eligible only if the noise clips produce no word.

Result: tuning in progress.

## H6. Where the engine's time goes

Measurement only, no decision. The transcribe.cpp CLI reports mel, encoder
and decoder milliseconds per input; `profile.py` collects them for the six
speed inputs and the six long takes on a quiet Mac. The tuning runs already
show the decoder at about 43 ms per frozen FLEURS file against roughly 115 ms
of engine time, so the decoder is about 38% of the engine and the mel front
end plus the Metal encoder the rest.

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
