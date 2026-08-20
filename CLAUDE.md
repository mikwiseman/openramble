# OpenRamble repository rules

## Active ASR research handoff

The complete August 2026 ASR performance/reliability state is archived in
[`research/asr-performance-2026-08/CONTINUATION_PROMPT.md`](research/asr-performance-2026-08/CONTINUATION_PROMPT.md).
Read that prompt and its linked experiment ledger before starting or repeating
any model, cache, benchmark, or streaming work.

OpenRamble is local dictation for macOS, Windows, and Linux: hold a key, speak,
release it, and receive text in the active application.

## Network boundary

The shipping app has exactly two network areas:

1. Explicit model downloads through
   `apps/desktop/src-tauri/src/adapters/download.rs`.
2. Native Sparkle update checks and downloads on macOS. Scheduled checks are
   enabled; downloading and installing an update always requires a click.

No other shipping code may access the network. The complete denied API list is
maintained in `scripts/check-network-surface.sh` and enforced by CI — by
filename on both sides, so the promise is checked rather than intended. Update
the public privacy description in `README.md` if this boundary ever changes.

## Architecture

- `apps/desktop` is the shipping Tauri shell on all three platforms.
- `core/` owns recognition, audio, session policy, text, model installation,
  and history. Recognition runs in the application process.
- `apps/macos` and `Packages/` are the retired Swift implementation retained as
  migration reference; they are not built into the release artifact.

### The shared core (cross-platform)

- `core/` is a Cargo workspace holding the dictation logic every platform
  shares: `ramble-core` (session machine, policies, gesture), `ramble-text`
  (pipeline, dictionary), `ramble-model` (installs), `ramble-audio`,
  `ramble-engine` (the only crate touching the inference runtime),
  `ramble-history`, and `ramble-ffi` (the Swift boundary).
- `ramble-core` and `ramble-text` perform no I/O whatsoever: no files, no
  devices, no network, no clock of their own. Time arrives as a parameter and
  effects leave as values. `SessionMachine` is the whole dictation flow in that
  shape — feed it events, carry out the effects it returns — which is why the
  desktop runner decides nothing itself.
- `apps/desktop` owns platform adapters and the Liquid Glass settings UI. Its
  network use is one named module and the gate checks it by filename.
- `core/conformance/` remains historical migration evidence. New behavior is
  specified and tested in Rust; do not add a second Swift implementation.

## Privacy and safety

- Never log dictated text, individual words, keystrokes, or user file names.
  Dictation history is the one place transcripts and audio are persisted; it is
  bounded by an explicit retention setting and documented in `README.md`.
- On macOS write to the clipboard only with `CurrentHostOnly` and the transient,
  concealed, and auto-generated markers. On Windows set the Cloud Clipboard and
  history exclusion formats. A plain clipboard write is prohibited.
- Do not add telemetry, analytics, cloud sync, or third-party reporting SDKs.
- Surface failures to the user; never silently discard a recording or result.

## Release invariants

- The bundle identifier `is.waiwai.dictation` is permanent because existing
  Accessibility permission grants depend on it.
- The existing Sparkle EdDSA key is permanent. Never generate a replacement.
- Sign Sparkle nested code from the inside out. Do not use `codesign --deep` for
  signing because it can replace required nested entitlements.

See [docs/release.md](docs/release.md) and [AGENTS.md](AGENTS.md).

## Development

- Prefer a failing test before the implementation.
- Keep policy decisions in small, pure types rather than view models.
- Before committing, run `./scripts/check.sh`.
- For a focused Rust change: `cargo test --locked -p <package>`, then
  `cargo clippy --locked -p <package> --all-targets -- -D warnings` and
  `cargo fmt --all --check`.
