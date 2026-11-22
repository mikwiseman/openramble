The clipboard check in the network gate was never running, so the gate's "all fine" meant nothing for clipboard writes. The gate now runs that check and catches violations, and the fix is committed on `work`. I didn't push.

**What happened:** `scripts/check-network-surface.sh` used `$FORBIDDEN_PASTEBOARD`, but nothing ever defined it. With `set -u`, the unbound variable killed the subshell running that check. Nothing reached the main script, and the surrounding `|| true` hid the failure, so the gate carried on and printed its pass message. The "no `clearContents()`" rule in CLAUDE.md therefore had no enforcement in this script.

**The fix:**
- I defined the pattern as `clearContents(` and `declareTypes(`. The old `declareTypes` call is another write that Universal Clipboard would sync.
- All source scans (network, clipboard, logging) now go through one helper. If grep errors, or a shipping path no longer exists, the gate stops with exit 2 and a `GATE ERROR` line.

**Proof it catches things:**
- **Real tree:** a temporary `NSPasteboard.general.clearContents()` file got `VIOLATION: flushing buffer…` and exit 1. A clean tree passes with no error output.
- **New test:** `scripts/tests/test-network-surface-gate.sh` builds throwaway fake repos and checks each rule fires: clipboard, forbidden network symbol, missing update keys, and transcript logging. It also checks that comments, the sanctioned `.currentHostOnly` write and the two allowed network files pass.
- **Original bug:** the test also confirms a gate with the variable undefined, a missing shipping path, or a broken pattern now fails.
- **Old gate:** the test fails against the old script on the unbound variable, so it would have caught this bug.
- **CI:** I added the test to CI next to `test-release-policy.sh`, and that existing test still passes.

**Decision for you:** I made the missing shipping path fatal. A renamed source folder would otherwise scan nothing and pass.

**Not done:** the runtime-binary check still skips itself when no build exists. That is the existing, documented behaviour and I left it alone.
