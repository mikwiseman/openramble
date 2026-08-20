# OpenRamble

Private, local dictation for macOS, Windows, and Linux.

Hold Right Control, speak, and release it. OpenRamble transcribes the recording
on this computer and inserts the text at the current cursor. The desktop shell
is Tauri on every supported platform; the recognition, audio, text, model, and
history code is shared Rust.

[Download OpenRamble](https://waiwai.is/ramble) ·
[Latest release](https://github.com/mikwiseman/openramble/releases/latest) ·
[Sparkle feed](https://mikwiseman.github.io/openramble/appcast.xml)

## Privacy

Recognition runs locally. Audio is not uploaded, accounts are not required,
and the app contains no analytics or crash-reporting SDK.

Recent successful dictations are stored locally with their audio in a bounded
history. They can be copied, deleted individually, or cleared from Settings.
Transcripts are never written to logs.

Recognition does not use the network. Two maintenance actions can:

| Action | Destination | Data visible to the service |
|---|---|---|
| Download the pinned model | Hugging Face CDN, with GitHub Releases fallback | IP address and download request |
| Check or download an update on macOS | GitHub Pages and GitHub Releases | IP address, app version, and download request |

Sparkle sends no system profile and never installs an update unattended. Its
native update UI verifies the permanent EdDSA signature used by existing Mac
installations.

On macOS, pasted and explicitly copied transcripts use the system’s
current-host-only option plus transient, concealed, and auto-generated
pasteboard markers. On Windows, the equivalent Cloud Clipboard and clipboard
history exclusion formats are set. OpenRamble restores a previous text
clipboard only while it still owns the temporary value, so a copy made by the
person during the restore delay always wins.

Offline recognition can be verified with an installed model:

```bash
./scripts/test-zero-network.sh
./scripts/test-zero-network-trace.sh
```

The first runs the Rust recognizer under a macOS deny-network sandbox. The
second uses a process-attributed interposer with a positive control and requires
zero DNS/connect/send calls from recognition.

## Stability design

- The microphone callback performs no allocation, disk I/O, or mutex wait. A
  fixed five-second SPSC ring transfers samples to a collector thread.
- Capture is stopped before the ring is drained, so the last audio frame cannot
  race with transcription.
- One lifecycle worker serializes start, stop, recognition, cancellation, and
  paste. A press during recognition is rejected instead of becoming a surprise
  queued recording.
- The model warms while speech is arriving and stays resident between takes.
- History uses one bounded writer. Disk pressure cannot block paste or grow an
  unbounded queue; index updates are durable temporary-file replacements.
- Clipboard and native UI work is scheduled on the platform main thread.
- The macOS app and Sparkle framework are universal `arm64` + `x86_64`; the
  Intel inference build disables host-specific CPU instructions.

## Requirements

**macOS**

- macOS 14 or later
- Apple Silicon or Intel
- Microphone and Accessibility permission

**Windows and Linux**

- Windows 10 or later, or a Linux desktop with X11 or Wayland
- Recognition currently runs on the processor and may be slower than Metal on
  a Mac; session restrictions are stated in Settings

**All platforms**

- About 740 MB for the recognition model, plus temporary verified-download
  space

## Local data

On macOS data is stored under
`~/Library/Application Support/OpenRamble`; Windows and Linux use their native
local application-data roots. This includes the pinned model, personal
dictionary, and bounded dictation history. An interrupted model promotion is
recovered before the app accepts dictation. Model files come from immutable
revisions and are checked against committed SHA-256 values.

## Build from source

The repository pins Rust 1.97.1. macOS packaging also needs Xcode command-line
tools; Windows and Linux need the system WebView/audio packages listed in CI.

```bash
git clone https://github.com/mikwiseman/openramble.git
cd openramble

./scripts/check.sh
./scripts/prepare-tauri-macos.sh   # macOS only; verifies Sparkle 2.9.4
cargo tauri build --config apps/desktop/src-tauri/tauri.conf.json
```

`./scripts/build-dmg.sh` creates an ad-hoc signed universal development DMG
named `OpenRambleDev` with the separate identifier
`is.waiwai.dictation.dev`. Publishing uses `./scripts/ship.sh` from a clean,
green `main` commit.

## Documentation

- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Release process](docs/release.md)
- [Handy and cross-platform audit](research/cross-platform-2026-08/HANDY_AUDIT_2026-08-20.md)
- [ASR research handoff](research/asr-performance-2026-08/CONTINUATION_PROMPT.md)

## License

The source code is licensed under the MIT License. The product name and icon are
not included in that license. Third-party notices are listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
