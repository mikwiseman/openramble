Fixed and committed (328b109 on branch `work`, not pushed). All six sentences now keep every word and lose only the hesitation; the three restarts still collapse. Same result with spoken corrections on and off.

**Cause.** The rule for a phrase begun again with another ending ("with the, um, with Kowalski's") read "it and" as an abandoned phrase and removed it with the hesitation. Same for "if", "that", "about", "и" and every other conjunction or preposition.

**Rule I chose.** After a joining word (conjunctions, prepositions, "that", "which"; English and Russian), words said again are kept unless the first copy opens the sentence, follows a comma, semicolon or colon, or follows an opening "So"/"And". After "and", "or", "but", "so", "then" they are always kept ("We tried and, um, we tried again").

**Where.** Both implementations, changed together:
- /Users/mikwiseman/.openramble/model-bench/work/r88-conjunction/run-fable/Packages/DictationCore/Sources/DictationCore/CleanVerbatim.swift
- /Users/mikwiseman/.openramble/model-bench/work/r88-conjunction/run-fable/core/ramble-text/src/clean.rs (the Rust core the Mac app, Windows and Linux actually run)
- 40 new corpus cases in core/conformance/corpus-text.json; fixtures regenerated from the Swift pipeline, additions only, no existing fixture changed.

**Checked.**
- New tests written first and watched failing on the old code, in Swift and in Rust.
- DictationCore, LocalASR and RambleCoreFFI suites pass; Rust fmt, clippy and tests pass; the Rust port replays all 506 fixtures; network and diagnostics gates pass.
- The nine sentences from the request also run correctly through the Swift-to-Rust bridge the Mac app uses.
- A sweep of 29,582 generated "X joiner, um, X …" sentences lost no word, apart from the nonsense "that that, um, that".
- Not run: the Mac app Xcode suite. It needs an XcodeGen download and the work was offline.

**Trade-offs you should know.**
- A restart in the middle of a sentence that stops on a joining word now keeps both copies: "We can meet at, uh, meet on Monday" becomes "We can meet at meet on Monday", and "Tell him I think that, um, I think we should wait" keeps "I think that". I chose extra words over any risk of lost ones. A narrow rule for a swapped preposition could bring the first kind back, at a small risk; say if you want it.
- Not changed: a clause that ends on "please", "is" or "can" and runs into the same word still loses words ("Send it please, um, it is urgent" becomes "Send it is urgent"). It is a different rule path with no joining word; say if you want that kept too.

No version bump, release notes or push.
