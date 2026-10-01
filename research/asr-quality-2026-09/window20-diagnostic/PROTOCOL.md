# Research-only 20-second windows: reject for production

The observed mixed-language 37-word omission motivates one predefined window
experiment. It is a development diagnostic on the already inspected three
system-voice parents. It provides no independent held-out group, meaningful
confidence interval or repeated idle latency gate.

Plan SHA256:
`98b5c3175450b2d31fea84f964005160afcbbe7385e47e9bc297f4f426525aea`.
Combined manifest SHA256:
`bd01f62acc5c83d0c610696ff9d21b8ab2bc8822c4ae9c258c654ed49b824d33`.
Execution declaration SHA256:
`3fa58bc8729559f6fcafa488d5d678f884704f1df1358ebab86321063f5bbb51`.
Candidate binary SHA256:
`a8e16d703e1c01c81151847e13289d7205816a804760d8b176d6054780e40a63`.

## Isolated producer and preserved controls

Copy LocalASR/DictationCore source packages outside the checkout, retaining
all 155 source/build-input hashes. Apply only the
[two initializer-default edits](source-patch.diff): `seconds: Int = 30` to
`seconds: Int = 20` in FileAudioChunks. Build release `asr-bench` with warnings
as errors; the same checksum-pinned transcribe.cpp 0.2.3 artifact comes from
cache. Original sources are checked against the snapshot after the run.

Minimum segment remains 15 seconds, overlap two seconds, forced-cut search
one second, and the timed joiner is unchanged. Inputs at or below 30 seconds
retain the direct path. Model weights/revision, one decoder thread, warm-up,
Rust pipeline and text settings remain unchanged. The candidate is a new
explicit producer; it never replaces the sealed v2 binary or relabels old
inference. Its source includes the unrelated CLI exit fix, which does not
change the quality command. See [execution identity](execution.json).

Every candidate fixture exactly matches its original frozen parent. Reuse
the original default-window outputs; validate model, thread, pipeline,
normalization, app settings and host equality. The generic paired-model
comparison rejects different binary producers, so this deliberate window
experiment uses the explicit [comparison summary](comparison-summary.json).
No confidence interval is estimated from one parent per language.

## Results and decision

| Input | Default app WER | 20s app WER | Default file wall | 20s file wall |
|---|---:|---:|---:|---:|
| RU | 2.88% | 2.92% | 31.665 s | 33.921 s |
| EN | 1.11% | 1.07% | 23.418 s | 23.963 s |
| Mixed | 17.21% | 14.71% | 29.037 s | 29.907 s |

All three candidate files succeed. Mixed WER improves 14.50% relative, with
RU/EN point changes of +0.032/-0.032 percentage points. Candidate file times
are 7.12%/2.33%/2.99% higher. These single observations are screens, not
accepted speed gates. The fresh candidate process loads in 9.001 seconds,
warms in 0.076 seconds and peaks at 917.2 MiB; the longer initial load remains
reported separately and is not attributed to the window change without
measurement. Memory covers all three inputs, unlike the separate earlier
baseline processes.

The [critical audit](critical-audit.json) reproduces primary S/D/I. Mixed's
longest consecutive deletion shrinks from 37 to 22 words and the final ten
words now match, but negative-marker nonmatches increase from three to five
(four deletions, one substitution). New omissions include contexts about
combining update times, the northern path and a week without exceptions.
RU/EN markers and endpoints remain intact. No app command is emitted.

Reject this variant for production despite its aggregate WER improvement:
material omissions remain and negative coverage gets worse. Keep default
windows and the shipping binary. No additional endpoint sweep is promoted
from this observed-script screen. Primary Eleven v4 coverage remains separate;
the same scripts spoken by another voice do not become new independent text
groups. A safe future fix requires independently scripted critical cases.

See [aggregate results](REPORT.md) and [complete candidate report](report.json).
Audio and individual outputs remain local outside Git.
