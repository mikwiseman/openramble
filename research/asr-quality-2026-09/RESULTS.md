# Current-runtime results and remaining checks

Keep the shipping Parakeet model. No tested candidate has established a safe
universal RU/EN replacement. The study is still open for primary Eleven v4 long tracks
and observable GUI Stop-to-insertion; neither is a passed check. The installed
application is published 0.31.2, with verified signatures, feed and native load.

## Main and independent public holdout

Strict app WER includes spelling numbers differently, digit/word conversion,
alphabet differences and retained failures. Models are Q8, Parakeet/GigaAM use
one decoder thread and the two Whisper controls use the preregistered four.
Do not average unlike speech domains into a single model-selection score.

| Source / language | N | Parakeet | Turbo | Breeze | GigaAM CTC |
|---|---:|---:|---:|---:|---:|
| Common Voice 19 test / EN | 500 | 8.06% | 12.84% | 9.65% | RU-only |
| Common Voice 19 test / RU | 500 | 5.62% | 7.88% | 10.05% | 2.24% |
| Golos Crowd / RU | 500 | 3.21% | 23.34% | 37.41% | 19.16% |
| Golos Farfield / RU | 500 | 7.37% | 19.90% | 38.39% | 7.23% |
| FLEURS test / EN | 647 | 5.44% | 4.92% | 5.39% | RU-only |
| FLEURS test / RU | 775 | 5.55% | 4.80% | 6.74% | 5.01% |

The [main comparison](main/REPORT.md), [GigaAM main comparison](giga-main/REPORT.md)
and [FLEURS comparison](holdout/REPORT.md) retain S/D/I, CER, process memory,
load/warm-up and grouped paired intervals in their companion JSON files.
GigaAM's [FLEURS subset comparison](holdout-ru/comparison.json) reuses the exact
original baseline inference; its memory covers the whole parent manifest.

Turbo's FLEURS EN difference is -0.515 percentage points, 95% grouped interval
[-0.910, -0.137]; the RU interval [-1.448, +0.188] crosses zero. GigaAM's RU
interval [-1.285, +0.407] also crosses zero. These results do not override the
main-domain regressions. FLEURS has one 33.84-second RU source: Turbo and Breeze
fail with native unsupported-token-timestamp code 12, GigaAM returns text
without requested word timings, and Parakeet succeeds. Each failure remains
in the WER denominator as an empty hypothesis. Timing summaries use successes.

Numeral formatting accounts for part of the Golos scores. An exploratory
[source-only lexical split](giga-main/numeric-strata.json) uses the same declared
vocabulary as the original comparison. On the 398 Crowd references without
listed numeric lexemes, Parakeet/GigaAM WER is still 3.85%/9.18%. On the 490
equivalent Farfield references it is 7.23%/6.16%. This is not a semantic-number
parser or a replacement for the preregistered complete sets.

## Short critical cases and extra checkpoints

The [36-recording grouped synthetic holdout](synthetic-holdout/REPORT.md) has
RU/EN/mixed app WER 9.09/10.62/11.46% for Parakeet, 3.03/5.49/8.33% for Turbo,
and 9.52/6.96/16.67% for Breeze. The [15-RU GigaAM subset](giga-synthetic-holdout/comparison.json)
scores 18.61%, versus Parakeet 9.09%; the paired interval is +1.32 to +21.76
percentage points. Voices of the same script are related; references are
intended fictional text with provider alignment, not human-verified spoken gold.
The [critical-case audit](CRITICAL-CASES.md) records preserved values/negations
and the material mixed-language clause/script failures separately from WER.

The exact mixed-script alias improves only two development outputs and changes
zero main, short holdout or FLEURS outputs. It remains a research candidate.
primeLine Q8 scores EN/RU 9.48/8.17% on the original 100+100 development screen,
versus shipping Parakeet 7.95/4.90%; both paired regression intervals exclude
zero. Do not extend that checkpoint as an accuracy winner.

GigaAM RNN-T ties CTC at 3.27% on 100 RU development inputs but is slower
(file p95 81 versus 62 ms). A separately frozen 15-RU technical development
screen scores app WER 11.39% for RNN-T, 13.50% for CTC and 10.55% for Parakeet.
It remains a small exploratory screen with five script groups; there is no
confirmed held-out RNN-T gain or claim about its larger datasets. Both GigaAM
heads are RU-only; no automatic language router has been added.

Five additional precisions of the exact shipping Parakeet checkpoint completed
the same 100 EN + 100 RU development screen, with no failures. The
[precision comparison](QUANTIZATION.md) covers Q4_K_M, Q5_K_M, Q6_K, F16 and
F32. None meets the declared 10% relative WER improvement. Q4 uses about 29%
less process memory; F16/F32 provide no established accuracy gain. Q5's small
EN improvement has an interval crossing zero and a RU point estimate just
over the +0.5 percentage-point limit. Keep Q8; screening timings do not
establish a repeated idle speed advantage or held-out quality.

## Unique long-file diagnostic

A separate offline Milena rendition of the full fictional RU script lasts
24 minutes 23.9 seconds without looping or padding. Parakeet recognizes it
in 31.665 seconds, raw/app WER 2.98%/2.88%, process peak 924.5 MiB. Turbo and
Breeze each fail with native unsupported-token-timestamp code 12. Their
failures remain in the denominator and are not successful speed results.

The [protocol and audit](system-long-diagnostic/PROTOCOL.md) preserve the
pre-inference manifest-header correction, fixed producer identity and the
single-parent scope. Whole-file raw alignment has no consecutive deletion
longer than one word, retains the first/last ten words and matches all 81
negative-marker instances. These checks do not establish preservation of
every negated clause or numeric value. Word timings are decoder outputs,
not reference alignment. The intended script is not independently verified
spoken gold. This diagnostic does not complete the Eleven v4 primary
RU/EN/mixed variants or establish a lossless seam guarantee.

The additional [EN/mixed offline diagnostics](system-long-extra/PROTOCOL.md)
last 18m18.8s/22m32.3s. Parakeet file times are 23.418/29.037 seconds and app
WER 1.11%/17.21%. Turbo and Breeze fail both with code 12. Mixed alignment
exposes a 37-word consecutive deletion and three nonmatching negative
markers; matching timestamps do not establish completeness. The text core
does not change those errors. All three decoders recover the missing clause
from a separately declared 18.64-second crop of the same PCM. This is an
observed-error diagnostic with no new independent quality example or speed
gate. A Russian system voice's English pronunciation remains a confound;
primary Eleven coverage is still required.

One separately declared [20-second window experiment](window20-diagnostic/PROTOCOL.md)
uses an isolated source copy, preserving original sources and v2. Mixed app
WER improves 14.50% relative (17.21% to 14.71%), but negative-marker nonmatches
rise from three to five and a 22-word consecutive omission remains. Reject
it for production. RU/EN WER point changes are only +0.032/-0.032 percentage
points; file time rises 7.12%/2.33%/2.99% across RU/EN/mixed. First-pass times
and observed scripts are not independent acceptance evidence. Lower WER alone
does not justify shipping a variant with worse critical coverage.

## Speed, resources and application scope

Repeated predecoded timing uses six frozen inputs per language, warmed once,
20 rounds in each fresh process and an ABBA process order. The first complete
Parakeet process was preserved after the collector rejected its known banner;
the parser was corrected and the remaining processes ran without re-inference.
The process bracket has that interruption; first/last baselines agree closely.
It was otherwise idle (about 84-86% host CPU idle, no competing ASR/preparation).
These repeated observations are not independent quality examples.

| Model / lane | p50 across two process brackets | p95 | Fresh process peak |
|---|---:|---:|---:|
| Parakeet / RU | 89-90 ms | 151-152 ms | 895.5-895.9 MiB |
| Parakeet / EN | 88-89 ms | 121-122 ms | same RU/EN process |
| GigaAM CTC / RU | 46 ms | 75 ms | 330.6-331.6 MiB |

See [raw aggregate timing](runtime/idle-latency.json). Output hashes are stable
for every input within each process. Load, file decode, microphone capture
and insertion are excluded. No faster default is inferred from RU-only speed.

A separate five-second [native profile](runtime/profile-summary.json) finds
69.61% of the sampled native-worker stacks waiting for Metal completion and
27.02% within the decoder subtree. These include blocked stacks, not a GPU
kernel profile or CPU-utilization split. Profiled observations are excluded
from every latency gate. Scheduler/dictionary changes have no demonstrated
speed benefit from this profile.

All three models process the five existing private recordings without failure:
file p50 is 0.19/1.35/2.20 seconds, respectively. Only [aggregates](runtime/private-runtime.json)
are curated; private audio, identifiers and transcripts stay local. There is
no independent reference, so this is a runtime check, not an accuracy score.

The [GUI attempt](runtime/gui-outcome.json) verifies native application launch
and model readiness. Computer Use cannot bind its menu-bar-only surface and
rejects the actual modifier-only Right Control before sending input. There
is no observable recording/Stop/insertion cycle and no GUI latency result.
This is a tool blocker, not an approval request or an application failure.

## Validation and autonomous continuation

All 14 CI checks passed on frozen-study commit `b938962` (also on `b7cfc88`).
The new CLI error regression fails on the unfixed binary with SIGABRT, then
passes after unloading the model before exit; the retained GigaAM timing error
now exits 70 cleanly. The diagnostic-only v3 binary does not replace the sealed
v2 quality producer. Its release build treats warnings as errors. All 39 Python
tests pass with the native opt-in regression enabled; the network-surface
check also passes. See
[red/green evidence](runtime/cli-error-regression.json) and the opt-in test at
`scripts/tests/test_asr_cli_errors.py`.

The known external ElevenLabs credit reset is October 1 at 13:25:21 Moscow.
The verified current-thread heartbeat resumes after it, rechecks quota and
generates the frozen genuine 4/5/8/15-minute RU/EN/mixed tracks within the
existing $20 cap. No billing changes, private upload, automatic retry of an
uncertain paid request, or extra permission question is required. Preserve
parent grouping, actual seams and failed outcomes. The long and GUI checks
remain outstanding; this document does not mark the full study complete.
