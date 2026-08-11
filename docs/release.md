# Release process

OpenRamble releases are Developer ID signed, notarized by Apple, stapled,
checked by Gatekeeper, signed for Sparkle with the permanent EdDSA key, uploaded
to GitHub Releases, and listed in the GitHub Pages appcast.

## Permanent identifiers

- Repository: `mikwiseman/openramble`
- Bundle identifier: `is.waiwai.dictation`
- Sparkle feed: `https://mikwiseman.github.io/openramble/appcast.xml`
- Download page: `https://wai.computer/openramble/`
- DMG name: `OpenRamble-<version>.dmg`

Do not change the production bundle identifier. Existing Accessibility grants
are attached to it.

Do not run Sparkle `generate_keys`. The public key embedded in existing builds
requires the matching private key. Recover the permanent key described in
[AGENTS.md](../AGENTS.md) if it is missing.

## Release-machine setup

Run once on a trusted Mac:

```bash
./scripts/bootstrap-release-secrets.sh
```

This validates or restores:

- the permanent Sparkle key at `~/.openramble/sparkle-key`;
- file-based App Store Connect API credentials;
- the dedicated offline Developer ID release keychain.

No login-keychain password or interactive prompt is required after the release
machine has been prepared.

## Preflight

The release script requires:

- a clean `main` branch exactly matching `origin/main`;
- a successful CI run for the same commit;
- matching marketing and bundle versions in `apps/macos/project.yml`;
- English release notes at `docs/release-notes/<version>.md`;
- an installed recognition model for both offline runtime checks;
- a valid Developer ID identity and App Store Connect notarization key;
- the permanent Sparkle private key.

Live voice benchmarks and the optional manual evidence matrix are not release
requirements.

## Build, sign, notarize, and update the feed

```bash
SPARKLE_KEY_PATH="$HOME/.openramble/sparkle-key" \
./scripts/release.sh
```

The script runs package and application tests, checks the shipping network
surface, performs two offline runtime checks, builds the arm64 app, signs nested
Sparkle components from the inside out, submits the DMG for notarization,
staples the ticket, verifies Gatekeeper acceptance, signs the exact DMG with
Sparkle EdDSA, verifies the embedded public key, and updates
`docs/appcast.xml`.

## Publish

Upload the exact verified image and use the matching English notes:

```bash
VERSION=0.3.7
gh release create "v$VERSION" \
  "artifacts/dmg/OpenRamble-$VERSION.dmg" \
  --repo mikwiseman/openramble \
  --title "OpenRamble $VERSION" \
  --notes-file "docs/release-notes/$VERSION.md"
```

Commit and push the appcast change, then verify:

```bash
curl -fsSL https://mikwiseman.github.io/openramble/appcast.xml
```

The enclosure URL, byte length, build number, and EdDSA signature in the live
feed must exactly match the uploaded DMG.

## Final checks

1. `xcrun stapler validate` accepts the DMG.
2. `spctl --assess --type install --verbose=2` accepts the DMG.
3. The app inside the mounted image has the expected bundle identifier,
   version, build, update URL, and public key.
4. The public landing page downloads the same DMG.
5. An older installed build can discover and install the update through
   Sparkle.
