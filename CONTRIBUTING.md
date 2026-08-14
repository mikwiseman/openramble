# Contributing to OpenRamble

Thank you for contributing. The primary product promise is that dictated audio
and text stay on the user's Mac.

## Non-negotiable boundaries

- Network access is limited to explicit model downloads and Sparkle updates.
  Scheduled update checks are enabled by default and can be disabled in
  Settings; downloading and installing an update always requires a click.
- Do not add analytics, telemetry, cloud sync, crash-reporting services, or new
  dependencies without prior discussion.
- Do not log speech, recognized text, keystrokes, or user file names.
- Clipboard writes must remain local to the current Mac.
- Do not include recordings or dictated text in issues or pull requests.

## Repository layout

- `Packages/ASRWorkerProtocol`: bounded private protocol shared by the app and
  its recognition worker.
- `Packages/DictationCore`: platform-independent dictation logic.
- `Packages/LocalASR`: model installation and local recognition.
- `apps/macos`: SwiftUI/AppKit application, system integrations, and the
  private persistent recognition worker embedded in the app bundle.

The Xcode project is generated from `apps/macos/project.yml`; do not edit the
generated `.xcodeproj`.

## Setup

```bash
git clone https://github.com/mikwiseman/openramble.git
cd openramble

swift test --package-path Packages/ASRWorkerProtocol
swift test --package-path Packages/DictationCore
swift test --package-path Packages/LocalASR
"$(./scripts/pinned-xcodegen.sh)" generate --spec apps/macos/project.yml
open apps/macos/OpenRamble.xcodeproj
```

The app is menu-bar-only and uses a separate development bundle identifier,
`is.waiwai.dictation.dev`, so development permissions do not affect the release
app.

## Verification

Run the complete local check before submitting a change:

```bash
./scripts/check.sh
```

Useful focused variants are `./scripts/check.sh --fast` for package-only work
and `./scripts/check.sh --app` for application-only work.

When an installed model is available, also run:

```bash
./scripts/test-zero-network.sh
./scripts/test-zero-network-trace.sh
```

Write comments that explain constraints and intent. Keep policies in testable
types and ensure every failure path produces a clear user-facing result.
