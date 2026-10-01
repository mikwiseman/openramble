# Unique offline long-file diagnostic

This additional diagnostic uses the complete original fictional `long-ru.txt`
once, rendered offline by macOS Milena at rate 165. No loops, repeated excerpts
or added silence extend it. Actual canonical duration is 1463.9223125 seconds
(24 minutes 23.9 seconds). It is separate from the frozen Eleven v4 primary
RU/EN/mixed tracks and their word-aligned 4/5/8/15-minute variants.

The source script is intended text, not independent spoken gold. There is no
provider word alignment. Do not substitute decoder timestamps for reference
timings or claim that every join has independently verified accuracy.

## Execution and recovery

The plan was frozen before generation, SHA256
`ed87e933cc91b21097d24f84d5c665dff0d86d3a7de22b4c509f0fde0aae54b8`.
Its first manifest omitted the schema-version header and was rejected before
any model process started. Preserve the rejected manifest (SHA256
`318da28b494cfb5dde30634bd704dae5f0057ec1bd0f63760cec325882c265dc`)
outside Git. A separate recovery declaration corrects only that header;
audio, fixtures and references remain identical. Recovery plan SHA256:
`7b6761242e374b0077b299dd43dedc12e66b900f711eb76349b2de722713648f`.
Corrected manifest SHA256:
`fbe2635eb8307408a1c3b099bd2eaa9d092b2cf732989c93585b99a0c5fdb158`.

Parakeet, Turbo and Breeze run serially with the unchanged v2 quality binary,
same original model revision/hash, one/four/four decoder threads, one model
load and warm-up per process, and baseline Rust text binary. Per-example
timeout remains 300 seconds. All processes exit normally; file failures are
preserved independently from process completion. One parent provides no
meaningful paired confidence interval, so none is estimated.

## Observations and limits

Parakeet succeeds in 31.665 seconds, process peak 924.5 MiB. Raw/app WER is
2.98%/2.88%, raw/app CER 1.12%/1.04%. This measures file decode and recognition,
excluding model load, recording, GUI Stop and insertion. Turbo and Breeze each
fail with native unsupported-token-timestamp code 12; empty hypotheses remain
in quality denominators. Their rapid failures are not successful speed results.

The [whole-file alignment audit](critical-audit.json) matches the primary raw
S/D/I: 80 substitutions, nine deletions, four insertions over 3121 reference
words. The longest consecutive deletion run is one word. All 81 aligned
instances of `не`, `ни` or `нельзя` match, and the first/last ten words are
retained. Marker matches alone do not establish that every negated clause or
number preserves meaning. All 3113 reported word intervals are within bounds
and have nondecreasing starts; the final word ends 62 ms before audio EOF.
No app command is emitted. This is limited diagnostic coverage, not a general
semantic gate or a result for English, mixed speech or natural conversation.

See [aggregate results](REPORT.md) and [execution provenance](comparison.json).
All audio and individual outputs remain outside Git in the local data root.
