# License, privacy, and artifact policy

The original research occupied 51.18 GiB and included model weights, compiled
bundles, builds, benchmark audio, corpus shards, traces, and caches. Committing
those bytes would be unsafe and unusable. The archive preserves source and proof.

## Included

- Authored source, tests, Markdown, small reports/logs, manifests, commands, and
  SHA-256 values.
- Textual Git diffs and metadata for isolated worktrees.
- Metadata-only inventories for excluded trees.
- Aggregate/public-fixture evidence that does not disclose private dictation.

## Excluded

- User recordings, private dictated text, and user file names.
- Corpus audio, including public datasets and the unofficial Common Voice mirror.
- Model weights, GGUF/Core ML artifacts, compiled bundles, and build caches.
- Binary traces, release images, executables, and credentials of every kind.
- Any artifact whose redistribution terms were not proven compatible.

Excluded artifacts are represented by provenance, size, SHA-256, commands,
configuration, license notes, and exclusion reason where available.

## Dataset caveats

- FLEURS used pinned public revisions and frozen references.
- The dominant-short corpus used an unofficial Common Voice 17 mirror. It is
  internal-only and must not be redistributed here.
- The 204-utterance corpus has no independent endpoint labels.

## Network wording

The worker links CFNetwork/URLSession symbols through LocalASR/FluidAudio. Model
loading is offline and packaged recognition passed under OS-level network denial,
but the binary is not transport-free. State only that the exposed worker protocol
has no download/network request and recognition was verified with network denied.

## Benchmark wording

No evidence supports a public universal “10× faster than Handy” claim. The fair
comparison is backend-only, patched, one-host, small-corpus, and did not prove
long-fixture quality noninferiority.
