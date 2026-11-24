The Rust conformance check passes now. The Rust port had not picked up the last Clean Verbatim change. The Mac side and the fixtures were already right, and I left them alone.

**What was wrong.** The Swift change added a rule to `revisedLength` in `CleanVerbatim.swift`. When the word before a hesitation is a conjunction or preposition (a new list called `joiningWords`), the words around the hesitation are not treated as a restart. The only exception is when the phrase begins at the start of a sentence or right after a comma. So "We shipped it and, um, it works." keeps both copies of "it". The Rust port never got this rule. It turned that sentence into "We shipped it works.", and 8 of 477 fixtures came out different from the Mac.

**Fix.** It is one file, `core/ramble-text/src/clean.rs`:
- I added a `JOINING_WORDS` list with the same 63 words as the Swift list (a script confirmed they match exactly).
- I added the same check to `revised_length`, ordered as in Swift so it can't step past the start of the text.
- I brought over the matching doc comments.
- I added a Rust unit test with the same 18 cases as the Swift test `testAWordSaidAgainAfterAConjunctionAndAHesitationStays`, run with spoken corrections both on and off. It failed on the old code and passes now.

**Checks:**
- I rebuilt the Swift fixture generator and recorded the corpus again. Both `pipeline.json` and `starter-dictionary.json` came out byte-for-byte the same as the committed files, which confirms the Mac is the reference and the fixtures are a true recording.
- `cargo test -p ramble-text --test conformance` passes on all 477 fixtures.
- I ran the shared-core Lint and Test steps from CI on this Mac: fmt, clippy with `-D warnings`, and the tests for the five core crates. All pass.
- I did not run the CI jobs for the desktop app or the Swift-calls-Rust boundary. This change doesn't touch either.

It is committed on branch `work` as 90f55d0 and not pushed.
