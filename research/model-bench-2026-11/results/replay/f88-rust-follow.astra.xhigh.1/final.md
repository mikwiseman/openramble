The Rust conformance check is green locally. Clean Verbatim now preserves both uses of “it” in “We shipped it and, um, it works.” All 477 cases match the regenerated Mac fixtures.

All 210 shared-core Rust tests, Clippy, and formatting passed. The repo’s fast check stopped at SwiftPM sandbox startup, but the DictationCore suite passed when run directly.

Committed locally as `7db5f68` on `work`. The working tree is clean.
