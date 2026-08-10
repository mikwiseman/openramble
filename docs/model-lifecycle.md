# Model lifecycle

OpenRamble downloads two pinned Core ML model distributions after explicit
user action: the main Parakeet TDT model and the vocabulary prompt model.

Each committed manifest defines:

- the upstream repository and immutable revision;
- every required relative file path;
- the exact byte count and SHA-256 checksum;
- an optional GitHub Releases mirror for availability.

Downloads first enter a unique staging directory. Every file is checked before
the complete revision is promoted atomically and marked ready. Interrupted,
partial, oversized, missing, or corrupted downloads are never treated as an
installed model.

Changing a model revision requires a regenerated manifest, updated attribution,
package tests, offline runtime checks, and a documented benchmark comparison.
Changing model quality does not block unrelated application releases, but no
quality claim should be made without matching evidence.

Model release assets are operational dependencies and must remain available
even when application release history is cleaned up.
