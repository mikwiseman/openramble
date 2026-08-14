# OpenRamble repository rules

OpenRamble is local dictation for macOS: hold a key, speak, release it, and
receive text in the active application.

## Network boundary

The shipping app has exactly two network areas:

1. Explicit model downloads through `LocalASR/ModelDownloading.swift`.
2. Sparkle update checks and downloads through `SparkleUpdater.swift`.
   Scheduled checks are enabled by default and can be disabled in Settings;
   downloading and installing an update always requires a click.

No other shipping code may access the network. The complete denied API list is
maintained in `scripts/check-network-surface.sh` and enforced by CI. Update the
public privacy description in `README.md` if this boundary ever changes.

## Architecture

- `Packages/ASRWorkerProtocol` defines the bounded private wire protocol shared
  by the app and its recognition worker.
- `Packages/DictationCore` contains platform-independent dictation logic and
  protocols for system boundaries.
- `Packages/LocalASR` depends on `DictationCore` and owns model installation and
  recognition. Only `FluidAudioAdapter.swift` may import FluidAudio.
- `apps/macos` contains the thin SwiftUI/AppKit application layer and the
  private persistent ASR worker embedded in the app bundle.

LocalASR depends on DictationCore. The app and private worker share
ASRWorkerProtocol; the worker also depends on LocalASR and DictationCore. No
package depends on the application layer.

## Privacy and safety

- Never log dictated text, individual words, keystrokes, or user file names.
- Write to the clipboard only with
  `prepareForNewContents(with: .currentHostOnly)` and the required transient and
  concealed markers. A plain `clearContents()` can leak dictation through
  Universal Clipboard and is prohibited.
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
- Before committing, run `./scripts/check.sh` or at minimum all three Swift
  package test suites.
