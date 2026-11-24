It was a real controller bug, not the test, and it is fixed. Commit `aba6b91` is on branch `work`, not pushed.

**Why it happened.** When I replay the storm's random numbers for seed 45, a hands-free take is stopped and then the storm presses again to start a hands-free take. If that press lands while the previous text is still being pasted, the controller saves it for later. While waiting, the controller kept only a press and its key release. The release does nothing to a hands-free take. The press that ends a hands-free take (`stopHandsFree`) was thrown away, and so was a double tap (`promoteToHandsFree`). After the paste, the saved take started and nothing could end it. That is exactly what CI saw: stuck listening, microphone on, the next dictation inserts nothing. It passed on the rerun because the test's fake paste finishes almost instantly, so presses rarely land during it.

**The fix** is in `Packages/DictationCore/Sources/DictationCore/DictationController.swift`. Every press, release, second press and double tap made while a paste finishes is now kept in order. Once the paste lands, they are applied one by one, as if they came a moment later. Escape or a shortcut still forgets them. A paste that does not land still drops them, as before, so its failure notice stays on screen.

**Tests**
- I added two tests to `DictationControllerTests.swift`: a hands-free start and stop during a paste, and a double tap during a paste. Both failed on the old code with the CI symptom and pass now.
- In `DictationControllerRaceTests.swift`, the storm's fake paste now holds for 3 ms after the text lands, like the real paste waiting to put the clipboard back. With that hold, the old controller fails seeds 45 and 72 on every run, the same failure both times. The fixed one passed the storm with 1, 3 and 6 ms holds, and the race tests passed 5 times in a row.
- All of DictationCore passes, built with warnings as errors: 641 DictationCore tests and 174 DictationAudio tests.
- LocalASR, RambleCoreFFI and the app tests were not run, because they need the network or generated build files. The change is private to the controller, so they cannot break at compile time.

**Decision for you:** the app still loses two kinds of key press during a paste before they reach the controller. I left both alone because I can't build or check the app offline.
- **A double tap.** `AppState`'s double-tap handler ignores the `.inserting` state, so it becomes a tap. Adding `.inserting` to the case that calls `promoteToHandsFree()` would fix it, because the controller now keeps that gesture.
- **A press while a hands-free take's text is pasted.** The hotkey treats it as "stop hands-free" and drops its release, because the hands-free flag stays on until the take is fully done. Clearing the flag when the hands-free take stops recording would fix it, but VoiceOver may then announce the take once more as an ordinary recording as it ends.

The Rust session machine has neither hands-free nor press-during-paste handling, and it didn't before this change, so I left it alone.
