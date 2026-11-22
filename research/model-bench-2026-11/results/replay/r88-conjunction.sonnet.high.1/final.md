Clean Verbatim no longer eats real words. All six of your examples now keep every word and drop only the hesitation. It's committed on `work` as `8f19fdc`, not pushed.

**Cause:** the restart check read "it and, um, it works" as a restart of "it and", because the words after the hesitation began with the same word. It then removed "it and" along with the "um".

**Fix:** a restart that ends on a connecting word (and, or, but, if, that, about, и, что and similar) now collapses only when it repeats a whole clause that opens a sentence or follows a comma.
- Your three restarts still collapse: "I think that, um, I think we should wait", the "Okay, …" version, and "Let's meet at, uh, let's meet on Monday".
- "with the, um, with Kowalski's" still collapses too.
- It's fixed in the macOS Swift code and the Rust port that Windows and Linux use. It works the same with spoken corrections on and off.

**Tradeoff I chose:** where the two readings pull against each other, I keep the words. "Ship the thing if, um, the thing passes" keeps "if", and a restart that begins mid-sentence and ends on a connector is no longer collapsed.

**Checks:**
- The new Swift tests failed before the fix and pass now.
- The full DictationCore suite (155 tests), the Rust text tests including the Mac-versus-Rust comparison, clippy and fmt all pass.
- I added your examples to the shared test corpus and regenerated the fixtures. Only new entries were added; no existing fixture changed.
- I did not run `scripts/check.sh` as a whole, so the macOS app build and the other checks in it were not run.

I did not bump the version or write release notes. That is a release step.
