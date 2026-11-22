The clipboard check in the network gate was dead, and it's fixed and committed on `work` (`a5b6fe2`, not pushed).

**What happened:** `scripts/check-network-surface.sh` searched for `$FORBIDDEN_PASTEBOARD`, which was never defined. The error killed only the subshell feeding the check, so the check read nothing and the gate exited 0. A plain `clearContents()` in shipping code would have passed. No violation is in the shipping code today.

**What I changed:**
- **Pattern defined:** it flags `clearContents(`, `declareTypes(`, and any `prepareForNewContents(` that isn't `(with: .currentHostOnly)`. The last two are my reading of the CLAUDE.md rule, since the original value is lost.
- **Fails closed:** a check that cannot run (undefined pattern, missing source directory, unreadable binary) now stops the gate.
- **Says what it caught:** violations go to stderr, because `release.sh` and `check.sh` discard the gate's stdout and a red gate used to exit silently.
- **No false vouching:** the gate no longer says the inference runtime "cannot reach the network" when that audit was skipped.

**Proof:** the new `scripts/tests/test-network-surface-gate.sh` plants violations in a throwaway copy of the shipping sources and runs in CI next to the gate. Same planted `clearContents()`, gate run the way `release.sh` runs it:

| Gate | Result |
|---|---|
| Before | prints `unbound variable`, exit 0 |
| After | names the file and line, exit 1 |

It also proves the gate catches:
- network symbols outside the two allowed files;
- each missing Sparkle update key;
- dictated text in logs;
- a runtime binary that opens a socket;
- its own pattern going missing.

Comments that mention `clearContents()` still pass.

**Not run:** LocalASR and app test suites, because they need to download binary artifacts and the work is offline. No Swift changed; DictationCore tests and `test-release-policy.sh` pass.

**Your call:** the release preflight still passes when the runtime binary isn't built yet — it now says "not audited" instead of claiming clean. The packaged-DMG smoke script has its own runtime audit; I did not run it. Say if you want the preflight skip to be a failure.
