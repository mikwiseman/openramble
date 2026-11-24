The network gate now blocks plain clipboard writes. The `FORBIDDEN_PASTEBOARD: unbound variable` error was a real hole in the clipboard check, and the gate had been passing without running it. The fix is committed on `work`, not pushed.

**What happened**
- `scripts/check-network-surface.sh` used `$FORBIDDEN_PASTEBOARD` but never defined it.
- `set -u` killed the subshell that feeds the clipboard loop. The loop saw no lines, and the script's exit code was 0.
- So the clipboard check never ran. A plain `clearContents()` would have passed.
- The two release callers (`check.sh` and `release.sh`) hide the gate's stdout, so the "all clear" was invisible. Only the stderr line showed.

**The fix**
- I defined the pattern as `clearContents\(|declareTypes\(`. I reconstructed it from CLAUDE.md, since the original definition isn't anywhere in the repo. Say so if you want a wider list. Comment lines are still ignored.
- The network, clipboard and text-logging checks now collect matches with `hits=$(scan …)` instead of `< <(…)`. A broken pattern, an unset variable or a grep error now aborts the gate with a non-zero exit instead of looking clean.
- I did not touch the two `nm`/`otool` loops in the runtime-binary audit. They have the same `< <(…)` weakness, but the runtime binary isn't built here, so I couldn't exercise a change.

**Proof**
- The new `scripts/tests/test-network-gate.sh` runs the real gate against throwaway trees. It also runs in CI.
- It confirms a clean tree passes. Comments mentioning the banned calls, and `URLSession` in the two allowed files, don't trip it.
- These seeded violations all fail the gate:
  - `clearContents()`
  - `declareTypes`
  - `URLSession` outside the allowed files
  - `Data(contentsOf:)`
  - a logged transcript
  - a missing update key
- A gate with the pattern deleted and a gate with an invalid regex both fail instead of passing.
- Against the old gate, the same test fails on the first seeded violation (`clearContents()` passed). The fixed gate passes it, including under `/bin/bash`.
- I ran only the gate and its test. I did not run `check.sh` or the Swift suites, since nothing in the Swift code changed.
