# OpenRamble

Private, local dictation for Apple Silicon Macs.

Hold a hotkey, speak, and release it. OpenRamble transcribes the recording on
your Mac and inserts the text at the current cursor.

There are no engine knobs to tune: model choice, memory residency, timing
budgets, and paste behavior are automatic and covered by tests. Under memory
pressure the app releases the recognition engine on its own and reloads it
under your next dictation — recording starts instantly either way.

[Download OpenRamble](https://waiwai.is/ramble) ·
[Latest release](https://github.com/mikwiseman/openramble/releases/latest) ·
[Sparkle feed](https://mikwiseman.github.io/openramble/appcast.xml)

OpenRamble is currently a public beta. Each published build is signed with
Developer ID, notarized by Apple, and distributed as a universal update to
existing beta installations.

## Privacy

Recognition runs locally. Audio is not uploaded, accounts are not required,
and the app contains no analytics or crash-reporting SDK.

Transcripts are never written to logs. Recent dictations **are** kept on this
Mac, with their audio, so you can replay, copy or delete them: the last 5 by
default, adjustable in Settings ▸ History, deletable individually or all at
once. Earlier versions kept transcripts in memory only; this is a deliberate
change, and it is the one thing this app stores that it previously did not.
Nothing leaves the Mac either way.

Recognition never uses the network. The following maintenance actions can:

| Action | Destination | Data visible to the service |
|---|---|---|
| Download a model | Hugging Face CDN, with a GitHub Releases fallback | IP address and download request |
| Check for updates | GitHub Pages | IP address and app version |
| Download an update | GitHub Releases | IP address and download request |

OpenRamble checks for updates automatically, so a fix reaches you without you
having to go looking for it. Turn scheduled checks off in Settings → Updates.

Two things stay off regardless: no report about your Mac, its system version or
language is sent with the check, and nothing installs on its own — an update
downloads and installs only after you click.

You can verify offline recognition with an already installed model:

```bash
./scripts/test-zero-network.sh
./scripts/test-zero-network-trace.sh
```

The first command runs recognition in a deny-network sandbox. The second uses a
process-attributed network trace without the sandbox. CI also performs a static
scan of the shipping network surface.

## Permissions

OpenRamble requires Microphone access to record speech and Accessibility
access to observe the selected global hotkey and insert completed text.

The global event monitor compares key events with the selected hotkey and
Escape. It does not log, store, or transmit unrelated keystrokes. Input
Monitoring permission is not required.

Optional correction learning is disabled by default. When enabled, OpenRamble
briefly re-reads only the field where it inserted text so it can learn a term
you corrected. It does not read other windows or screen content.

## Local data

Application data is stored under
`~/Library/Application Support/OpenRamble`:

| Data | Retention |
|---|---|
| Recognition models | Until removed in Settings |
| Current recording | Queued for local deletion after success or explicit cancellation |
| Recovery audio after a technical failure | Up to 10 WAV files, seven days, and 1 GiB |
| Dictation history: transcripts and their audio | The last 5 by default (5–50 in Settings ▸ History); older entries and their recordings are deleted when they fall off |
| Settings and replacement dictionary | Stored in macOS defaults |
| Text that could not be inserted | Memory only, until the next dictation or app exit |

When a technical failure or interrupted process leaves recovery audio,
OpenRamble discloses a newly recovered take and shows `Recovered Recordings
(N)…` in the menu. That command opens the exact Finder folder for Preview or
Delete; retained voice is never transcribed again in the background.

Deletion runs outside the microphone/UI path so a stalled filesystem cannot
freeze dictation. If the bounded cleanup lane cannot persist exact file
identities, OpenRamble fails closed: it disables automatic audio recovery,
leaves ambiguous bytes untouched, and shows `Recording Support Files —
Recovery Disabled…` until the Support folder is inspected. Cancellation is
not described as power-loss durable before its local intent reaches disk.

Upgrading from a build released under the previous product name moves the old
Application Support directory automatically. The bundle identifier remains
`is.waiwai.dictation` so existing Accessibility permission continues to work.

## Usage

- Hold the configured hotkey, speak, and release it to insert text.
- Double-press the hotkey to record without holding it; press again to stop.
- Press Escape while recording to cancel.
- Use “Copy Last as Spoken” to copy the raw recognition result before
  dictionary replacements and typography cleanup. The item appears when that
  raw text differs from what was inserted.
- A single dictation can run for up to five minutes. At the limit OpenRamble
  stops cleanly and transcribes the complete captured audio instead of risking
  an incomplete take when disk storage is unavailable.
- Choose whether the compact dictation panel appears at the top or bottom of
  the active display in Settings → General.

Clipboard insertion preserves the previous clipboard contents in memory and
restores them within two seconds — including screenshots and other non-text
content, byte for byte. The dictated text is written with host-only, transient,
and concealed markers, so it does not enter Universal Clipboard on your other
devices or clipboard-manager history. Concealed password-manager values, file
promises, and clipboard contents larger than 16 MiB are never copied; the
dictated text stays available in the menu — “Insert Last Dictation” and
Recent Dictations — instead.

## Requirements

**macOS**

- macOS 14 or later
- Apple Silicon; Intel Macs are not supported

**Windows and Linux**

- Windows 10 or later (x86_64), or a Linux desktop with X11 or Wayland
- Recognition runs on the processor on these platforms today, so it is slower
  than on a Mac. It is stated in Settings rather than left to be discovered.

**Both**

- About 740 MB for the recognition model, plus temporary space while it is
  downloaded and verified

Model files are downloaded from pinned revisions and verified against committed
SHA-256 checksums before installation.

## Build from source

Xcode with the Swift 6 toolchain is required. XcodeGen is downloaded at a pinned
version and verified by SHA-256.

```bash
git clone https://github.com/mikwiseman/openramble.git
cd openramble

swift test --package-path Packages/DictationCore
swift test --package-path Packages/LocalASR

"$(./scripts/pinned-xcodegen.sh)" generate --spec apps/macos/project.yml
xcodebuild -project apps/macos/OpenRamble.xcodeproj -scheme OpenRamble \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
```

Build a development DMG with `./scripts/build-dmg.sh`. Development builds use
the separate name `OpenRambleDev` and bundle identifier
`is.waiwai.dictation.dev`.

## Documentation

- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Manual verification](docs/manual-check.md)
- [Release process](docs/release.md)
- [Benchmark methodology](docs/benchmarks.md)
- [Model lifecycle](docs/model-lifecycle.md)

## License

The source code is licensed under the MIT License. The product name and icon are
not included in that license. Third-party notices are listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
