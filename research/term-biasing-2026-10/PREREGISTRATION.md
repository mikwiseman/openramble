# Preregistration: phrase boosting for vocabulary terms

Written and committed on 19 October 2026, before any biased decode was run.
The rules below fix how the boost weight is chosen and when the feature is
adopted. A later change to a rule is written down next to the result, and the
result under the original rule is reported as well.

## What is tested

The runtime change is commit `81d40989` in a local transcribe.cpp checkout:
transcribe.cpp v0.4.0 plus phrase boosting for the Parakeet transducer
decoders, which honors `transcribe_run_params::vocabulary`. The app change is
`TranscribeCppAdapter.setVocabulary` on branch `claude/term-biasing`. The model
is Parakeet v3 Q8, SHA-256 `5859f779…`. The vocabulary is the 60 written forms
in `vocabulary.txt`, taken from `corpus.json`.

The corpus is 70 synthetic sentences read by macOS voices. Even rows are the
dev half and odd rows the test half. The test half is not recognized with any
vocabulary until the weight is fixed.

## Choosing the weight, on the dev half only

`tune.py` recognizes the dev half and the frozen 200 FLEURS files with the
whole vocabulary at weights 0, 0.5, 1, 1.5, 2, 3 and 4. Weight 0 is the
unbiased decode. The chosen weight is the one with the highest pooled dev term
recall among the weights whose FLEURS WER is at most 0.10 percentage points
above weight 0's in each language. A tie goes to the smaller weight. The
runtime default is then set to that weight and the runtime is rebuilt.

## The gate, on the test half and on all FLEURS

`v3-vocabulary` (the rebuilt runtime with the vocabulary) is compared with
`v3-vocabulary-off` (the same runtime and adapter with no terms) and with
`runtime-0.4.0` (the upstream runtime). Phrase boosting is adopted when all of
these hold:

1. Pooled term recall on the test half rises by at least 5 percentage points,
   and falls in neither language.
2. On all 1,422 FLEURS English and Russian test utterances, with the whole
   vocabulary active, the upper end of the 95% paired bootstrap interval for
   the pooled WER difference is at most +0.10 percentage points.
3. With no terms, the boosting runtime gives transcripts identical to
   `runtime-0.4.0` on all 1,422 FLEURS utterances.
4. With the vocabulary active, no word is invented on the noise clips and the
   wrong-script count on FLEURS and the private clips does not rise.
5. Warm p50 with the vocabulary active is at most 5% above the control's, in
   an interleaved speed run.

If the feature fails a rule, it is not adopted, and the report says which rule
failed and by how much.

## Result of the first attempt and a second hypothesis (H4b)

Added on 20 October 2026, after the gate above ran and before any H4b code
existed.

At the chosen weight 3.0 the first design passed rules 1 and 3 and failed
rules 2 and 4. Pooled FLEURS WER rose by 0.071 percentage points with an upper
95% bound of +0.137, above the +0.10 limit, and the noise clips produced 18
invented words, among them "Postgres." on two seconds of digital silence. The
bonus on a term's first token could outscore blank, so biasing changed whether
the decoder emitted anything, not only what it emitted. That design is not
adopted.

H4b keeps the decision between blank and a token unbiased: the decoder first
takes the model's own argmax, and only when that is a non-blank token does the
vocabulary re-rank the non-blank tokens. Biasing can then change which word is
written but never whether one is written, so it cannot invent speech on
silence or drop words that the model emitted.

H4b is tested with the same procedure and the same gate as above, with three
changes fixed now:

- The weight grid is 1, 2, 3, 4, 6 and 8, because re-ranking alone may
  tolerate larger bonuses.
- A weight is eligible only if, besides the FLEURS rule, the noise clips
  produce no word at all with the whole vocabulary active.
- The candidates are rebuilt from the H4b commit; their names stay
  `v3-vocabulary` and `v3-vocabulary-off`, and the first attempt's results are
  kept in the report.
