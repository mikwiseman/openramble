The controller can end up exactly like that, and it's fixed in commit `d9798bd` on `work`. Nothing is pushed.

**Cause:** A hands-free take started while a paste was still finishing. A second press during that same paste was dropped, because `stopHandsFree()` does nothing while the controller is inserting. The replayed take then listened with nothing to stop it. A new test, `testHandsFreeGesturesDuringAPasteReplayInOrder`, reproduces this deterministically. It failed before the fix with the session listening and the microphone on.

**Fix:** Every gesture made during a paste is now queued in order and replayed the moment the controller goes idle, so each one does what it would have done a moment later.

**Behaviour changes to check:**
- A press that ends a failed paste (nobody read it) now starts its take. I updated `testAPressWhileThePasteWaitsForItsReadEndsTheWaitOutLoud`, which said that press was not a take.
- A shortcut pressed during a paste (Right ⌘ then Return) now starts a take and is cancelled, which briefly turns the microphone on. I updated `testAShortcutPressedWhileALandedPasteFinishesIsCancelledLikeAnyOther`, which said it started nothing. This is the one to confirm. I can drop cancels from the queue if you prefer the old behaviour.

**Verification:** DictationCore passes (174 tests), LocalASR passes (22, 3 skipped as before), and the race suite passed four repeated runs. I did not run RambleCoreFFI because it needs a generated XCFramework that isn't in the repo, and I didn't touch it. I also didn't run `check.sh`, so the app target was not built.

**Not done:** The Rust port (`core/ramble-core/src/session/machine.rs`) still ignores presses during insertion. `CLAUDE.md` says behaviour changes go in both places, so it needs porting as a follow-up.
