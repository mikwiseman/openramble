# Long dictation validation — 0.31.2

Host: Apple M4 Pro, 24 GiB, macOS 27.0 (26A428). Runtime and model unchanged.
No user audio, transcripts or model weights are included in this evidence.

## Failure-first checks

Against 0.31.1, the new tests reproduced healthy capture freeze at 800 ms and
WAV readiness at 2.5 seconds being reported as failures. Cancelling a gated
stream still launched all three old segments. Long memory/file inputs reached
the engine as complete 240, 300, 480 and 900 second buffers.

With the changes, healthy finalization succeeds, explicit short test deadlines
still retain failure containment, cancellation skips old queued work, and
marker transcripts contain every marker once. Native windows are bounded by
the existing 30-second policy plus context and short-tail merging (at most
36 seconds in the regression fixture). Forced model reload invalidates the
whole operation; a failed middle chunk cannot publish a partial success.

## Real-model long-input matrix

Command: `OPENRAMBLE_LONG_DICTATION_GATE=1 swift test --package-path
Packages/LocalASR --filter 'LongInputQualityTests|FileQualityTests|FileBackedStreamingTests|LongInputRoutingTests'`.

System voices Milena and Samantha read committed, harmless reference paragraphs.
The inputs contain continuous speech, rather than a short sentence padded to
several minutes. The eight-minute inputs include deterministic noise at 0.025
amplitude to prevent the ordinary quiet-pause rule from supplying easy cuts.
The reference and 8% maximum word-error rate are fixed in the test before ASR.
Every final marker is present exactly once.

| Voice | Audio seconds | Noise | Whole-input wall seconds | Engine seconds | Word-error rate |
|---|---:|---|---:|---:|---:|
| Milena | 241.82 | no | 3.31 | 3.29 | 3.56% |
| Milena | 304.24 | no | 4.20 | 4.17 | 3.76% |
| Milena | 493.86 | yes | 6.81 | 6.79 | 3.86% |
| Milena | 909.13 | no | 12.41 | 12.38 | 3.40% |
| Samantha | 243.85 | no | 3.24 | 3.21 | 0% |
| Samantha | 304.54 | no | 4.13 | 4.11 | 0% |
| Samantha | 485.88 | yes | 6.64 | 6.61 | 0.07% |
| Samantha | 909.46 | no | 12.20 | 12.17 | 0% |

Peak RSS across the complete test process was 1,204,699,136 bytes (1.12 GiB).
This is a cumulative process high-water mark, not an incremental model size or
an independent peak for each row. File-backed prefix reuse still reads the WAV
into PCM; this change bounds inference, not all memory for arbitrary durations.

The separate eight-minute streamed-prefix regression still used only one tail
decode after Stop and completed in 0.198 seconds. That is a ready-prefix case,
not a latency promise for uninterrupted speech or a queued engine.

The existing Russian file-quality baseline deliberately bypasses the new router
and calls native one-shot inference. The 30-second path had 20 versus 22 word
errors on the 455-word reference, and 37 versus 39 on the 109-word mixed-language
reference. This establishes no added errors on those fixtures, not universal
accuracy or a new accuracy claim.

Synthetic voices do not cover natural accents, hesitation or every microphone.
Grisha's 0.31.0 report cannot establish the original failure cause. A new field
report can distinguish finalization timeout, failed streaming and engine error.

## Integration checks

The repository's complete `scripts/check.sh` passed: Swift packages, 188 shared
Rust tests, the Swift/Rust boundary, conformance fixtures, 609 application tests,
application artifact and network/diagnostics policy checks. The local Rust 1.97.1
cache was shared with the unchanged release checkout because this host rejects
new proc-macro dylibs built under the longer worktree path (LINKEDIT alignment).
No product build settings or gates were disabled.

## Signed candidate and CPU load

The clean 0a65900 candidate (0.31.2, build 74) passed Developer ID validation,
Apple notarization, mounted-DMG checks, and packaged CLI recognition with the
network denied on both arm64 and x86_64. All 14 pull-request CI jobs passed.

A separate 493.86-second Russian fixture with synthetic noise ran through the
signed packaged CLI while eight CPU load processes were active. Cold-process
wall time, including model loading, was 16.97 seconds; maximum RSS was
971,915,264 bytes (0.91 GiB), and reported peak footprint was 1,035,142,800 bytes.
The fixed 1,036-word reference had 43 word errors (4.15%); the final marker
appeared once. These numbers describe that host and controlled input.
