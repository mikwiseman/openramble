Fixed and committed as `a241eb3` on branch `work`. Not pushed.

All six reported sentences now come out with their words intact. The three real restarts still collapse.

**Cause:** the restart rule treated "and", "if", "about" and similar words as restart words, so when the word before the hesitation came back after it, the connective was dropped with the copy.

**Fix:** a single repeated word now revises only a determiner ("It's a, uh, it's an"). A two-word repeat can also revise a preposition or "that" ("Let's meet at, uh, let's meet on Monday"). Conjunctions and "if" are never revised away. Where the rules pull against each other, this keeps extra words rather than losing them.

**Where:** the Swift pipeline (macOS, the spec) and the Rust port (Windows/Linux) both changed. The conformance corpus gained the reported cases, and fixtures were regenerated from the Swift pipeline. The 466 existing fixtures are unchanged.

**Verified:**
- Swift DictationCore: 155 tests pass. The new test failed before the fix.
- Rust: 270 tests pass, plus clippy with `-D warnings` and `cargo fmt --check`.

**Not run:**
- LocalASR needs a remote binary, so its suite needs the network, which is off-limits here.
- RambleCoreFFI doesn't cover this behavior.
- `scripts/check.sh` warms a network cache, so I didn't run it.

**Not done:** the README's "0 of 160 examples lost a real word" was measured before this fix and I haven't re-scored it. Nothing is released; `ship.sh` is still yours to run.
