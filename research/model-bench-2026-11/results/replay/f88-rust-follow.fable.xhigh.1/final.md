The Rust conformance test is green again. Committed on `work` as `0c7cf7f`, not pushed.

**Cause.** The last Clean Verbatim change on the Mac added a rule the Rust port never received: a word said again after a conjunction or preposition is two words, not a restart ("We shipped it and, um, it works" keeps both "it"). Rust still deleted "it and", so 8 of 477 recordings diverged.

**Fix.** One file, `/Users/mikwiseman/.openramble/model-bench/work/f88-rust-follow/run-fable/core/ramble-text/src/clean.rs`:
- Added the `JOINING_WORDS` list, identical to Swift's `joiningWords`.
- Added the same guard in `revised_length`: a phrase that stops on a joining word is begun again only from a sentence's start or a comma.
- Mirrored the Swift test for the rule as a Rust unit test (18 cases, both with and without spoken corrections). It failed before the fix and passes after.
- Updated the two doc comments to match the Swift wording.

**Checked.**
- `cargo test -p ramble-text --test conformance` passes, 477 of 477.
- The CI gate for the core crates passes: `cargo fmt --all --check`, clippy with `-D warnings`, and 211 tests.
- The fixtures were not edited. I regenerated them from the Swift pipeline and got no diff, so the committed recordings are what the Mac produces.
- All 49 word lists in the Swift file and the Rust port are now identical in content and order, so this was the only drift in the lists.

**Not run.** The full `./scripts/check.sh` (Swift package suites, the FFI bridge build, the app tests): the work was offline and no Swift code changed.

**Decision I made.** I ran the fixture generator as a check, which rewrites the fixture files in place; the output was byte-identical, so nothing changed in git.
