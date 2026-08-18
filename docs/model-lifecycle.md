# Model lifecycle

OpenRamble downloads two pinned Core ML model distributions after explicit
user action: the main Parakeet TDT model and the vocabulary prompt model.

Each committed manifest defines:

- the upstream repository and immutable revision;
- every required relative file path;
- the exact byte count and SHA-256 checksum;
- an optional GitHub Releases mirror for availability.

Downloads first enter a unique staging directory. Every file is checked before
the complete revision is promoted atomically and marked ready. Interrupted,
partial, oversized, missing, or corrupted downloads are never treated as an
installed model.

Changing a model revision requires a regenerated manifest, updated attribution,
package tests, offline runtime checks, and a documented benchmark comparison.
Changing model quality does not block unrelated application releases, but no
quality claim should be made without matching evidence.

Model release assets are operational dependencies and must remain available
even when application release history is cleaned up.

## Engine residency and reload economics

The loaded engine costs about 2.4 GB of resident memory; the reload after
giving it back is dominated by CoreML/ANE program specialization, whose OS
cache (`com.apple.e5rt.e5bundlecache`) macOS purges under memory pressure.
Measured on an M4: about 0.1–0.2 s to reload while that cache is intact,
13.5–16 s after a purge. Every rule below exists to keep that second number
away from the person's dictation.

When the engine's memory is given back:

- **Critical memory pressure** always evicts a safely idle engine
  (zero-settings behavior, unchanged).
- **The "Unload model" setting** (Behavior tab; Never / Immediately /
  2 / 5 / 10 / 15 minutes / 1 hour, **default "Never"**) returns the memory
  after that much dictation-idle time.

  The default was "After 5 minutes" through 0.8.2, on the argument that the
  comeback rides under the voice. The measured reload economics below say that
  is true only while the specialization cache survives: 0.15 s warm against
  13.5-16 s after a purge, and the purge is ordinary on a machine under memory
  pressure. A short take is the worst case, because it has no speech to hide
  the reload under and the person waits through the whole load staring at
  "Transcribing…". The countdown therefore stopped being a default and became
  a choice; critical-pressure eviction remains the automatic floor.

What an unload does: the worker process stays alive and drops its models
(protocol v2 `unloadModels`), so a comeback pays no process spawn, dyld, or
framework init. A worker that cannot answer the unload verb in five seconds
is killed by exact PID, as before.

When the engine comes back:

- the dictation key press, before any readiness guard — the reload rides
  under the voice (app activation and wake are gentler hints);
- pressure easing to normal — immediately; easing to warning — after a
  10-second settle window; never proactively under critical pressure;
- at stop, a still-loading engine is waited out (up to 25 s, well under the
  worker's 30 s watchdog) and the words are inserted normally; the recovery
  file remains only for genuinely wedged loads. Nothing is ever silently
  dropped.

Crash recovery also respects pressure: a worker killed under critical
pressure is respawned only after a jittered 5–10 s recheck shows the tier
eased, and never ahead of a real keypress-driven prepare.

Encoder placement stays `.automatic` (`MLComputeUnits.all`): on the measured
M4 it matches the Neural Engine's ~25 ms encoder against the GPU's ~87 ms.
Re-pinning `.gpu` (the 0.5.0 approach) would bound the worst cold reload near
7 s but slow every dictation 2–4×; with the reload economics above, the rare
purged-cache worst case is a visible bounded wait that still delivers the
words. `WAI_ASR_ENCODER_PLACEMENT` remains an asr-bench lane and is never
read by the shipping app. `scripts/bench-cold-reload.sh` reproduces all of
these numbers, including the cache-purge cliff via an APFS clone at a fresh
path.
