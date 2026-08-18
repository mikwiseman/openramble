# Model lifecycle

OpenRamble downloads one pinned model after explicit user action: Parakeet TDT
0.6B v3, as a single GGUF file.

Each committed manifest defines:

- the upstream repository and immutable revision;
- every required relative file path;
- the exact byte count and SHA-256 checksum;
- an optional GitHub Releases mirror for availability.

Downloads first enter a unique staging directory. Every file is checked before
the complete revision is promoted atomically and marked ready. Interrupted,
partial, oversized, missing, or corrupted downloads are never treated as an
installed model.

Changing a model revision — or its quantization; the repository also publishes
F32, F16, Q6_K, Q5_K_M and Q4_K_M builds of the same weights — requires a
regenerated manifest, updated attribution, package tests, offline runtime
checks, and a documented comparison.
Changing model quality does not block unrelated application releases, but no
quality claim should be made without matching evidence.

Model release assets are operational dependencies and must remain available
even when application release history is cleaned up.

## Engine residency and reload economics

The engine is a single GGUF file of about 740 MB, run on Metal by
transcribe.cpp. Measured on an M4: **976 MB peak process memory**, a warm model
load of **0.29 s**, and a first-ever load of about 7 s while the OS builds the
Metal library it then caches. Recognition runs at RTF 0.02–0.11, and a
half-second take costs about 29 ms.

None of that needs managing, which is the point of the numbers being here.

The engine this replaced cost 2.4 GB resident and, far worse, spent its load
time on Core ML program specialization for the Neural Engine — cached by the OS
in `com.apple.e5rt.e5bundlecache`, a cache macOS purges exactly when memory is
short. A purged cache made the next load take **13.5–16 s**. The engine was
therefore at its slowest precisely when the machine was already struggling, and
its own 2.4 GB made that struggle likelier.

Almost every lifecycle rule this document used to describe existed to keep that
number away from a person mid-dictation: idle-unload timers, memory-pressure
eviction, proactive rewarm with settle windows, a preparation phase in the UI, a
wait-and-insert path at stop, and jittered respawn backoff for a worker that
jetsam had killed. They are gone, because their cause is.

What remains is simple enough to state in full:

- the model loads when the app becomes ready, and stays loaded;
- a stop-time load, if one is somehow still in flight, is waited out and the
  words are inserted normally — the panel says "Waking the model…" rather than
  claiming to transcribe;
- nothing is unloaded on a timer.

Encoder placement is pinned to Metal rather than left to the OS. That costs a
little in the best case and removes an entire class of variance: with an
automatic placement the same recording could take a very different path
depending on what else on the Mac wanted the accelerator, which is not
something anyone can explain to the person waiting.
