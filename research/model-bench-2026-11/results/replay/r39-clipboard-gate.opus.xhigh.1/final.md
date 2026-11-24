The clipboard check never ran, so the gate never looked for clipboard leaks at all. It does now. I also added a test showing the gate fails on everything it guards. Committed as `e74d082` on the current branch, not pushed.

**What happened.** `FORBIDDEN_PASTEBOARD` was never defined anywhere. The clipboard search ran inside `< <(...)`, and under `set -u` the missing variable killed only that subshell. The loop read nothing, the gate's status stayed 0, and it reported a clean surface right under the error. The other searches had the same hole because they hid errors with `2>/dev/null || true`. I confirmed that a `URLSession` inside a renamed app folder passed the old gate with no hint, and a pattern that doesn't compile would have passed too.

**The fix**, in `scripts/check-network-surface.sh`:
- **Pattern defined.** It flags `clearContents()`, `declareTypes(...)`, and `prepareForNewContents()` with no options. Only `prepareForNewContents(with: .currentHostOnly)` passes.
- **A search that can't run now fails the gate.** Every search runs in the gate's own shell, so a missing pattern, a broken pattern or a moved folder stops it. "No match" still passes.
- **Violations go to stderr.** `release.sh` and `check.sh` throw away stdout, so a caught violation used to stop the release without saying why. Now it names the file and line.

**Proof.** I swapped one real host-only write in `TextInserter.swift` for `clearContents()` and ran both gates the way `release.sh` does:
- Old gate: printed the unbound-variable error, exit 0.
- New gate: `VIOLATION ... TextInserter.swift:275: pasteboard.clearContents()`, exit 1.

The new test, `scripts/tests/test-network-surface.sh` (about 2 seconds, runs in CI and `check.sh`), works on scratch copies of the tree. It checks that the clean tree passes. Then it plants each case below and requires a failure that names it:
- all 18 denied network APIs
- the 4 clipboard writes that can leave this Mac
- dictated text in a log
- each of the 3 required update settings, flipped
- a compiled runtime that calls `getaddrinfo`, and one that links Network.framework
- the gate with its clipboard pattern deleted (this incident), and a shipping folder that's gone

All cases pass. If the old gate only gets the missing variable added, the test still rejects it, because that version still passes when a check can't run.

**Not verified:**
- I didn't run the LocalASR and app test suites: they need network downloads, and no Swift changed. The gate stage of `check.sh` and the release policy test pass.
- The binary check was tested on dylibs I compiled, not the real transcribe.cpp runtime binary, which needs a build.

One older issue I left alone: each violation heading prints only once per run. So if a network leak and a clipboard leak both turn up, the clipboard lines appear under the network heading. The gate still fails; only the label is wrong. It's a small fix if you want it.
