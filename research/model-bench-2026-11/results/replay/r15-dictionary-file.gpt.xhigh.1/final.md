Committed as `61708ba` on `work`. DictationCore now reads and writes hand-editable dictionary JSON. Exports omit IDs and default settings. Imports trim phrases, skip blanks, and merge case-insensitively while preserving existing IDs and order. Counts reflect actual additions and updates. For duplicate phrases, the first existing match and first valid imported match take precedence.

All 347 tests in the DictationCore package and the network check passed. LocalASR was blocked by the missing offline FluidAudio dependency.
