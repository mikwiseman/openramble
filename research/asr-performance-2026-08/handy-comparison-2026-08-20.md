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

OpenRamble serialises the same two things. `DictationController` waits for the
take to be drained and sealed, then calls the engine. That wait is bounded only
by a two-second deadline which *fails* the take rather than degrading it.

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
