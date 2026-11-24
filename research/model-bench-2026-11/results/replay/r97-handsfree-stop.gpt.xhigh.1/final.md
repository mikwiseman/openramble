Confirmed and fixed the race. A hands-free stop could disappear while the previous paste finished, leaving the microphone on and blocking the next dictation. The first valid press now queues one take, and release, double-tap, hands-free stop, and cancel apply to that take.

Committed as `bdb20da` on `work`. All 816 DictationCore package tests passed, including the 200-seed storm and three deterministic regressions. The Swift bridge and Rust conformance checks also passed. The macOS app and LocalASR suites couldn’t run offline because the pinned inference binary was unavailable.
