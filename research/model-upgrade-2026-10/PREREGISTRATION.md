# Preregistration: runtime 0.4.0 and the next model

Written and committed on 19 October 2026, before any output from transcribe.cpp
0.4.0, Parakeet Ultra or Nemotron 3.5 was produced on this Mac. The decision
rules below are fixed now. If a rule turns out to be wrong, the change and the
reason will be written down next to the result, and the result under the
original rule will be reported as well.

What was already known when this was written:

- The upstream model pages report FLEURS test WER for Q8_0 of 4.83% (English)
  and 6.54% (Russian) for v3, 4.26% and 5.63% for Parakeet Ultra, and 12.61%
  (Russian) for Nemotron 3.5, with a separate English figure of 7.99% for the
  NeMo reference on FLEURS English. Those numbers use a different normalizer
  and the full test sets, on CUDA.
- OpenRamble 0.32.0 scored 5.57% (English) and 5.95% (Russian) on the frozen
  100-file subsets on 9 October.
- No transcript of any candidate on this Mac had been seen.

All candidates run through the same `TranscribeCppAdapter`, the shipping
adapter, with Metal and one decoder thread, through `asr-bench serve` built
from a named commit. Candidate files are in `research/scorecard/candidates/`.

## Part 1. Runtime A/A: v3 on 0.2.3 against v3 on 0.4.0

A is `runtime-0.2.3` (the 0.32.0 engine source, commit `3c5aaf9`). B is
`runtime-0.4.0` (commit `59e0355`, which changes only the runtime pin and the
manifest's runtime version). Both use the same v3 Q8 file, SHA-256 `5859f779…`.

B is adopted when all of these hold:

1. On all 1,422 FLEURS English and Russian test utterances, at least 99% of
   normalized transcripts are identical, and the paired pooled WER difference
   is within plus or minus 0.10 percentage points. Every differing transcript
   is listed in the report.
2. Wrong-script decodes on FLEURS and on the 199 private clips are not more
   than A's, and invented words on the noise clips are not more than A's.
3. Hour-file deleted-word rates differ by at most 0.2 percentage points.
4. In one interleaved speed run, B's warm p50 and p95 are at most 5% above A's
   plus 2 ms, both idle and under load, and B's whole-process p50 is at most
   10% above A's.
5. B's peak resident memory is at most 5% above A's.
6. The LocalASR unit tests and the model end-to-end tests have no failure
   under B that they do not also have under A.
7. The runtime binary passes the audit in `scripts/check-network-surface.sh`.

If B fails any rule, commit `59e0355` is reverted and the report says which
rule failed.

## Part 2. Model bake-off: v3, Parakeet Ultra, Nemotron 3.5

The candidates are `runtime-0.4.0` (v3), `parakeet-ultra` and `nemotron-3.5`,
all on transcribe.cpp 0.4.0. No language hint is given to any of them,
because the app has no language setting. For Nemotron this selects the
model's own automatic language slot. Orukeet is excluded because its
CC-BY-SA-4.0 license would carry share-alike terms into a derivative, and
the upstream page reports it below Ultra on every language.

The licenses were checked before any run. Parakeet Ultra is CC-BY-4.0, at
both `moondream/parakeet-ultra` and `handy-computer/parakeet-ultra-gguf`, the
same as v3. Nemotron 3.5 is OpenMDW-1.1, which allows use and redistribution
free of charge and requires keeping the agreement and notices with any copy.
Both pass the license screen.

### Primary measure

The primary measure is pooled WER on all 1,422 FLEURS English and Russian test
utterances, with the October 9 normalization. The difference from v3 gets a
95% interval from a paired bootstrap over utterances (10,000 resamples, seed
20261019).

### Gates

A candidate is eligible only if it passes every gate, each measured against
v3 on the same runtime:

1. No failed recognition on any public input.
2. Invented words on the eleven noise clips are not more than v3's.
3. Wrong-script decodes on all FLEURS utterances plus the 199 private clips
   are not more than v3's.
4. Hour-file deleted-word rates for English and Russian are at most 0.5
   percentage points above v3's, and the alternating hour's WER is at most
   1 percentage point above v3's.
5. Warm p95 over all speed inputs is at most 1.15 times v3's, both idle and
   under load.
6. Peak resident memory is at most 1.10 times v3's.
7. Punctuation micro F1 and capitalization F1 on full FLEURS are at most 1
   percentage point below v3's in each language.

### Decision rule

- Among eligible candidates, the one with the lowest pooled WER is
  recommended, provided the upper end of its 95% interval against v3 is below
  zero, and its WER in neither language is more than 0.25 percentage points
  above v3's.
- If two candidates qualify and their pooled WER differs by less than 0.2
  percentage points, the one with the lower warm p95 is recommended, and on a
  further tie the one that needs no change outside the model file.
- If no candidate qualifies, the recommendation is to keep v3.
- Exactly one model is recommended, because two resident models would double
  memory.

Nemotron's live streaming text is a product capability that this bake-off
does not score. It would be evaluated separately only if Nemotron won on
the rule above.

### Reported but not decisive

The frozen 100-file scorecard WER, WER on the six long dictation takes,
whole-process latency, model load time, model file size and per-language
intervals are reported for every candidate and do not change the decision.

## Procedure

1. Accuracy suites run per candidate in any order, because recognition is
   deterministic and does not depend on timing.
2. One interleaved speed run covers every candidate on the scorecard, so
   their speed numbers share the same machine state. A timed block starts
   only when the Mac is at least 85% idle and no other recognition process
   runs.
3. Scores, intervals and the gate table are computed with
   `scripts/scorecard/scorecard.py score`, `paired` and `compare`, and the
   reports are written in this folder.
