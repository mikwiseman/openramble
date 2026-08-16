# Release process

OpenRamble releases are Developer ID signed, notarized by Apple, stapled,
checked by Gatekeeper, signed for Sparkle with the permanent EdDSA key, uploaded
to GitHub Releases, and listed in the GitHub Pages appcast.

## Permanent identifiers

- Repository: `mikwiseman/openramble`
- Bundle identifier: `is.waiwai.dictation`
- Private ASR worker signature identifier: `is.waiwai.dictation.asr-worker`
- Sparkle feed: `https://mikwiseman.github.io/openramble/appcast.xml`
- Download page: `https://waiwai.is/ramble` — the product's main landing. It
  pins the version, the build number and the DMG link, so every release must
  update it (`apps/web/src/app/ww/ramble/page.tsx` in `wai-web`, guarded by
  `page.content.test.ts`).
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
  `WAI_MODELS_ROOT` is honoured by them, so keep a release-only copy
  (`~/.openramble/release-models`, installed with `asr-bench install` and
  `install-vocab` under that root) and export it for the release. A machine
  wiped for a from-scratch install test can then still cut a release, and the
  release never depends on the tester's own installation;
- a valid Developer ID identity and App Store Connect notarization key;
- the permanent Sparkle private key.

Live voice benchmarks and the optional manual evidence matrix are not release
requirements.

## Build, sign, notarize, and update the feed

```bash
WAI_MODELS_ROOT="$HOME/.openramble/release-models" \
SPARKLE_KEY_PATH="$HOME/.openramble/sparkle-key" \
./scripts/release.sh
```

The script runs package and application tests, checks the shipping network
surface and the worker control plane, performs two in-process offline runtime
checks, and always creates a fresh arm64 archive and DMG from the checked-out
SHA. It rechecks that HEAD and tracked inputs stayed unchanged before the
archive and again after exact-DMG verification. Reusing an earlier artifact is
deliberately unsupported.

CI also runs `UNSIGNED_RELEASE_TOPOLOGY=1 ./scripts/build-dmg.sh`. That mode is
CI-only and ad-hoc signed, but it exercises the production product name,
permanent bundle identifier, Release configuration, archive layout, and DMG
name. It is structural coverage only; it cannot substitute for Developer ID,
notarization, Gatekeeper, or the release-time offline-recognition gate.

The build signs nested Sparkle components and the private ASR worker from the
inside out, submits the DMG for notarization, staples the ticket, and verifies
Gatekeeper acceptance. It then mounts that exact read-only DMG and verifies the
app name, production bundle identifier, version, build, feed URL, permanent
public key, minimum macOS version, signatures, entitlements, architectures,
resources, and private worker identifier. Finally, the packaged worker loads
the installed model, warms inference, and recognizes a synthetic fixture while
an OS sandbox denies all network access. Only after those checks does the
script sign the same DMG with Sparkle EdDSA and update `docs/appcast.xml`.

The current worker links the complete `LocalASR` product, so its binary still
contains CFNetwork/URLSession downloader code even though the private worker
protocol exposes no download or install request. The smoke test reports that
fact explicitly. Do not describe this binary as transport-free: the enforced
release guarantee is successful packaged recognition under the OS network
deny. Removing the symbols requires splitting a runtime-only LocalASR product.

## Publish

Upload the exact verified image and use the matching English notes:

```bash
VERSION=0.7.0
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
4. `Contents/MacOS/openramble-asr-worker` has its fixed signature identifier
   and recognizes the synthetic fixture with `network*` denied by the OS; no
   test fixture or MCP executable is present in the application.
5. The main landing at `https://waiwai.is/ramble` shows this version and build
   and downloads the same DMG.
6. An older installed build can discover and install the update through
   Sparkle.
