# What Handy does that we do not — read from its source

Read directly from `cjpais/Handy`, cloned at HEAD on 2026-08-20. Quotes are the
repository's own code and comments, not paraphrase.

## The difference that matters

`src-tauri/src/actions.rs:682-716`. On key release Handy takes the samples from
memory, and then:

```rust
// Save WAV concurrently with transcription
let wav_handle = tauri::async_runtime::spawn_blocking(move || {
    crate::audio_toolkit::save_wav_file(&wav_path, &samples_for_wav)
});

// Transcribe concurrently with WAV save.
let transcription_time = Instant::now();
```

The file write goes to a blocking thread and recognition runs beside it. Handy
never waits for the recording to be written before recognising it.

**Correction, checked before acting on it.** OpenRamble has such a wait, but
not on the path it actually takes. `readableURL()` is only awaited in the file
branch; production goes through `freezeActiveRecording`, which awaits nothing
but `context.pcm.freeze()` and reports 0.03 s in the field logs. The
compatibility branch that does wait is not the one the app uses.

So this difference is real in Handy's source and does not describe our bug. It
is recorded because it was the leading hypothesis and because writing down a
disproved one is cheaper than rediscovering it. The remaining unexplained span
is the wait to enter the `LocalTranscriber` actor, which nothing measured until
now.

Handy also times the handover explicitly:

```rust
debug!("Recording stopped and samples retrieved in {:?}, sample count: {}",
       stop_recording_time.elapsed(), samples.len());
```

That is precisely the span that was unmeasured here through four rounds.

## Why our instrumentation kept reading zero

Three timers were added and all three reported `0.00` on takes lasting seconds.
The reasons, in order, each found only after the next round failed:

1. The queue timer was stamped one line *after* the WAV decode.
2. The `prepare` figure measured a different call on a different code path.
3. Every timer lived on the **file** path; the app takes the **in-memory** one.
4. The stamps sat *inside* `LocalTranscriber`, which is an actor — so the wait
   to enter the actor, which is where a suspended dictation queues, was outside
   what they measured.

All four numbers were true. None was about the thing that was slow. The lesson
is recorded here because it cost more than the bugs did: a measurement placed
by intuition tends to land where you already believe the problem is not.

## Still to check in Handy

- How it warms the engine, and whether anything runs per dictation.
- What happens after the text is produced, and whether it can delay the next take.
- Its streaming path (`finalize_stream`), which we have no equivalent of.

## The cause, measured

Caught under deliberate load on 2026-08-20 with `transport` — the stage added
in 0.22.0, which measures from dispatching the recognition call to the engine
starting work.

| total | engine | transport | audio |
|---|---|---|---|
| 31.00 s | 1.31 s | **29.66 s** | 16.5 s |
| 11.32 s | 0.28 s | **11.01 s** | 17.4 s |
| 8.15 s | 0.12 s | **8.00 s** | 6.9 s |
| 6.62 s | 0.18 s | **6.40 s** | 10.1 s |
| 4.92 s | 0.17 s | **4.72 s** | 12.1 s |

The engine is never the problem. The dictation is not working during those
seconds — it is waiting for a thread. `transcribe_run` is a synchronous C call
made from inside `TranscribeCppAdapter`, whose executor is Swift's cooperative
pool: one thread per core, and a thread blocked there is lost rather than
yielded. Under load the call waits for a slot while the work itself is ready.

Handy has no such queue — `src-tauri/src/actions.rs` hands its engine call to a
blocking thread.

Reproduces on demand: saturate the cores, dictate, and it appears within a
minute. That makes any fix testable rather than hopeful.

## Attempted fix, reverted

Moving `transcribe_run` to a dedicated queue via a checked continuation.
`swift test` caught it: `testScenario002` — the first of two consecutive
dictations came back with empty text. Reverted; 150/150 green again.

The C session handle and run params are not `Sendable`, and passing them across
a thread boundary needs more care than a mechanical `nonisolated(unsafe)`.
Shipping recognition that sometimes returns nothing would be worse than
shipping recognition that is sometimes slow.

Second time in one day that touching working code on a structural argument
rather than on evidence caused a regression; the first was moving the WAV seal,
which deadlocked the capture suite. The measurement is what earns the next
attempt.
