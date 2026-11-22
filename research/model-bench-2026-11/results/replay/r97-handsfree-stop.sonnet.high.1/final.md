Yes, the controller could really end up like that. It's fixed and committed on `work` (856777f).

**Cause:** a press during a landed paste is held and replayed once the paste ends. The gestures that followed it were not. The test hit this case:

- A hands-free press arrives during the paste.
- The key press that ends hands-free mode (`stopHandsFree`) arrives during the same paste and is dropped.
- The take then starts and listens, and nothing ends it. The microphone stays on and the next dictation inserts nothing.

The window is only a few milliseconds, which is why it passed on the rerun and why I could not reproduce seed 45 directly.

**Two more gaps in the same place, now fixed:**
- A double tap's promotion to hands-free was dropped, so the tap's release ended the take.
- A second press overwrote the first press's recorded release.

**Fix:** the held press now records each of these gestures and replays them on the new take in order. A second press is ignored, as it would be a moment later. Escape still discards the held press.

**Tests:** I wrote three tests first. All three failed on the old code, one with exactly your symptom (the take left listening). All three pass now, and the full DictationCore suite passes, including the storm.

**One change I could not check:** `AppState.swift` was dropping a double tap while a paste was finishing. It now passes it to the controller. I did not build the macOS app, and no existing app test depends on that case.
