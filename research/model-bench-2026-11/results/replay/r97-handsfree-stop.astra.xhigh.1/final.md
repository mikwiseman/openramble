Seed 45 exposed a real controller race. During a paste, the controller remembered the next hands-free start but lost its stop. A deterministic test reproduced the open microphone and the missed next dictation.

The fix preserves the next take’s gesture through both live and recovered pastes. A release ends a hold, a double-tap promotes it, and a hands-free stop ends it.

All 200 storm seeds passed. The three Swift package suites had zero failures and 31 skips. Mac app tests remain unverified because the pinned XcodeGen was unavailable offline.

Committed locally as `3b3213c`. The working tree is clean.
