Implemented version 1 dictionary export, import, and merge in DictationCore. Exports omit IDs and default settings. Restoring a backup preserves existing IDs and order, and importing it again reports zero changes. Repeated spoken phrases match in occurrence order so both entries survive a move.

Committed locally as `9b61deb` on `work`. The working tree is clean.

The DictationCore package suite, all seven transfer tests, and the network-surface check passed. LocalASR tests were blocked because FluidAudio was unavailable offline.
