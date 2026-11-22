**Cause:** `FORBIDDEN_PASTEBOARD` was used in `scripts/check-network-surface.sh` but never defined. Under `set -u`, the failed expansion killed only the process substitution that feeds the clipboard loop. The loop read nothing, the rest of the gate passed, and the script exited 0. A naked `clearContents()` would have shipped without a warning.

**Fix (commit `f7bd258` on `work`, not pushed):**
- Defined the pattern as `clearContents\(\)`, matching the rule in CLAUDE.md.
- Added `scripts/tests/test-network-gate.sh`. It runs the gate on copies of the shipping tree and checks that a clean tree passes, a naked `clearContents()` fails, a clipboard call in a comment passes, and a `URLSession` outside the allowed files fails.
- The test failed before the fix ("naked clearContents() was not caught (exit 0)") and passes after it.
- It now runs from `check.sh` and the CI network job.

**Proof the gate catches it:** I seeded `board.clearContents()` into `TextInserter.swift` and ran the real gate. It printed the VIOLATION block with the file and line and exited 1. I then reverted the file. `check.sh --fast` is green, and the release policy test passes.

**Not changed:** the binary audit of the inference runtime is skipped when no build exists, and CI runs the gate without one. So that check never runs in CI. It is a separate gap, and I left it alone.
