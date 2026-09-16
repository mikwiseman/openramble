# Local transcription implementation and evidence

This work keeps the existing Parakeet Q8_0 weights and one CPU decoder thread
for dictation. Measurements below must come from this implementation, not the
archived Core ML experiments. Audio and private transcripts stay outside Git.

## Acceptance log

- Model-store regression: two tests run against PR #58 before the fix; seven
  assertions failed. Inspection removed active staging, removed a backup and
  Finder metadata, and promoted a backup over a partially installed revision.
- The read-only inspection API now shares inventory/hash validation without
  recovery, cleanup or marker writes. GUI maintenance keeps its existing path.
- Initial installed-model suite exposed two existing fixture expectations:
  case-sensitive `linter` versus `Linter`, and a strict expected failure for
  `send it` that now succeeds. These are not speed or quality regressions.
- Machine: Mac16,8, 24 GiB RAM, 14 physical CPU cores. Runtime baseline 0.2.0.
  Candidate 0.2.3 XCFramework SHA-256:
  `944be4d5232f39c99608f676a2ddda2516e0ed3c9fb6db50685ffa8d20a8b9c9`.

## Required comparisons

Compare identical audio in paired runs, after warming the model. Record total
wall time, text parity, word timing bounds, peak RSS and swap. Do not count a
skipped live test as verification. Keep cold-start cost separate from steady
state. Report synthetic endurance audio as synthetic, not as a three-hour
human recording.

1. 15/30/60-second chunks, batches 1/2/4/8; compare normalized text for each
   identical input against sequential inference.
2. Two independently loaded models versus one native batch; include RAM cost.
3. Runtime 0.2.0 versus 0.2.3: short dictation, long audio and repeated runs.
4. Cancellation while queued and while running; recovery of the next request.
5. CLI yielding to GUI dictation, including process termination while holding
   the priority signal; finished chunks must survive a yielded batch.
6. RU/EN/mixed speech, stereo, silence, damaged input, interrupted output,
   chunk boundaries, names/numbers, short tails and long-file bounded memory.
7. Packaged CLI with GUI closed, paths containing spaces and network denied;
   installed skill invocation in Codex and Claude Code.

Only adopt performance profiles with a repeatable gain of at least 10% and
passing quality/latency checks. If profiles differ by less than 5%, prefer the
lower-memory one. Measurements below apply to this machine and corpus.

## Measured decisions (2026-09-16)

The base CLI fix landed in PR #58, commit
`2a933adedd13aceaf9c858b8066ea8fd4b6c08a3`; its corrected fork head
`1cdab1ecf23afbe131a3d6652dada1240603f1c4` passed all 14 CI jobs.
The packaged CLI recognized the synthetic English fixture with the GUI closed,
a path containing spaces, and OS network denial (positive control: EPERM).

**Adopt runtime 0.2.3.** The existing GGUF is unchanged. Alternating 0.2.0/0.2.3
and 0.2.3/0.2.0 runs gave identical normalized transcripts for all 240 short
inferences. See `latency-runtime.csv`: p50/p95 in milliseconds were 58/65 →
45/46 (1.89 s English), 92/102 → 73/76 (4.30 s synthetic Russian), and
327/365 → 275/286 (18.27 s human Russian). These are engine call timings,
not microphone-to-paste measurements. Peak process memory was 1056 → 907 MiB.

**Keep one model in production; two models remain a benchmark experiment.**
`long-files.jsonl` records a real 79.32-minute stereo conversation: one model
needed 72.02 / 75.55 s including load; two needed 48.81 / 51.66 s. All four
outputs have the same normalized text hash, 10,676 words, ordered timestamps,
and the last word ends at 4759.23 of 4759.24 s. Peaks were 951–1165 MiB versus
1740–1953 MiB. The tested parallel profile is one 30-second fragment per model,
with up to two ready batches. The user chose the simpler one-model path:
roughly 25 seconds saved on this recording do not justify another 0.8 GiB
and parallel scheduling in the shipping CLI. Automatic memory thresholds and
the second model were removed from the file pipeline. The `batch-benchmark`
command retains independent models for experiments; `file-benchmark` measures
the shipping one-model pipeline. Dictation retains one decoder CPU thread.

A two-model experiment on a repeated conversation, concatenated to three hours for endurance,
completed in 141.23 s including load, with 1968 MiB peak memory. Its 24,231
words have valid ordered times and retain the last audible word (10799.71 s).
This is not a distinct three-hour human conversation or a human WER reference.
System swap was already in use before these tests (about 15 GiB early in the
session, 5.7 GiB after); it decreased during this session, not a zero-swap claim.

**Do not enable multi-item native batches in production yet.** `batch-matrix.csv`
covers 15/30/60 s × 1/2/4/8 and independent-model candidates, three alternating
paired rounds per profile. Fixed-clip parity passed, but a complete variable
length human corpus changed one word with batch size two. On runtime 0.2.3 most
single-model batch gains were also below the 10% adoption threshold. Keep the
adapter and benchmark API for reproducing the finding; the CLI selects batch
size one. Meeting backlog batching was implemented and tested, then removed
before landing because this quality gate failed. Existing meeting order and
channel routing remain; meetings benefit from the runtime upgrade.

## Correctness findings

- A right-only stereo fixture failed with zero signal: AVAudioConverter's
  default remaps channel zero instead of mixing channels. Explicit downmix
  fixes it. Previous stereo tests had identical content in both channels.
  Preliminary human-file speed runs before this correction are invalid as
  whole-conversation benchmarks and are excluded from `long-files.jsonl`.
- The live microphone silence threshold discarded quiet imported audio.
  A 61 s sub-threshold fixture reproduced complete loss. File import now keeps
  quiet audio while reusing pause/quiet-frame boundaries; only digital zero
  chunks are skipped. The original live meeting policy is unchanged.
- The three-minute synthetic quality reference contains 455 words. Whole-file
  decoding had 22 normalized word edits; 15/30/60 s chunking had 19/20/16.
  The chosen 30 s profile preserved all five repeated paragraphs and the tail.
  This quality test asserts no degradation against whole-file decoding.
- A deterministic engine gate proved cancelled work returned stale text before
  the post-inference check. Cancellation now reaches the native abort callback
  and rejects stale results. Upstream Parakeet 0.2.3 does not poll during its
  one-shot GPU graph: a running call finishes before it can yield. Bounded file
  chunks stop the rest of the job; no claim of mid-graph preemption is made.
- A packaged SIGINT check found a Swift 6 executor assertion in the global
  signal callback. Marking that closure `@Sendable` removes inherited main
  actor isolation. Both waiting and active cancellation now pass, with finished
  outputs preserved and no partial output published.
- A fractional-millisecond subtitle fixture reproduced an end timestamp past
  the source duration. Millisecond quantization now rounds down.
- `scripts/tests/test-cli-transcription.py` passes under OS network denial:
  TXT/JSON/SRT/VTT, paths with spaces, original word times, right-only stereo,
  corrupt input beside valid files, duplicate stems, no overwrite, priority
  pause/resume with identical output, SIGINT while waiting and while processing.
  It is also part of signed artifact verification.

## Client skill acceptance

The same installed skill completed a real synthetic-file job in Codex CLI
0.154.0-alpha.6.2 (bundled with the desktop app) and Claude Code 2.1.270. Both
read/invoked the skill, ran the packaged CLI's help and model check, waited for
transcription, and inspected the resulting JSON. Both returned five words with
the last word ending at 1.76 s. The older Codex binary on PATH could not run the
account's configured model; the bundled current client passed without changing
the user's client configuration or chosen model.
