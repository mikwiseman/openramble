# Release process

OpenRamble releases are Developer ID signed, notarized by Apple, stapled,
checked by Gatekeeper, signed for Sparkle with the permanent EdDSA key, uploaded
to GitHub Releases, and listed in the GitHub Pages appcast.

## Permanent identifiers

- Repository: `mikwiseman/openramble`
- Bundle identifier: `is.waiwai.dictation`
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
- matching version and bundle build in `apps/desktop/src-tauri/tauri.conf.json`;
- English release notes at `docs/release-notes/<version>.md`;
- an installed recognition model for both offline runtime checks;
  `WAI_MODELS_ROOT` is honoured by them, so keep a release-only copy
  (`~/.openramble/release-models`) and export it for the release. A machine
  wiped for a from-scratch install test can then still cut a release, and the
  release never depends on the tester's own installation;
- a valid Developer ID identity and App Store Connect notarization key;
- the permanent Sparkle private key.

Live voice benchmarks and the optional manual evidence matrix are not release
requirements.

## Shipping

```bash
./scripts/ship.sh
```

That is the whole command, from any directory in the repository. It moves the
release worktree to `origin/main`, finds the Sparkle key, the signing identity
and the model root, runs the build below, creates the GitHub release, uploads
the image, publishes the feed, and then **fetches the live feed off the
internet and reads it**. It either ends by printing that the version is live
and its image downloads, or it fails.

Use `./scripts/ship.sh --dry-run` to check that a release could run — version,
notes, keys, identity, model — without building anything.

That last step is not ceremony. `release.sh` alone ends by printing four things
to do by hand, and those four steps are where releases die: 0.11.1 was built
and version-bumped and never existed for anyone, because the tail was never
run and nothing said so. The feed kept serving 0.11.0 and looked healthy doing
it. A release is not a build that succeeded; it is a feed that serves it.

### Build, sign, notarize, and update the feed

`ship.sh` calls this; run it directly only when you want the build without the
publish.

```bash
WAI_MODELS_ROOT="$HOME/.openramble/release-models" \
SPARKLE_KEY_PATH="$HOME/.openramble/sparkle-key" \
./scripts/release.sh
```

Never pipe it into `tail` or `head` to shorten the output. A pipeline reports
the exit code of its last command, so a refusal to build reads as a release
that worked — which is exactly how a release goes missing.

The script runs the full Rust workspace, checks the shipping network and
clipboard privacy surfaces, performs two in-process offline runtime checks, and
always creates a fresh universal Intel + Apple Silicon Tauri app and DMG from
the checked-out SHA. It rechecks that HEAD and tracked inputs stayed unchanged before the
archive and again after exact-DMG verification. Reusing an earlier artifact is
deliberately unsupported.

CI also runs `UNSIGNED_RELEASE_TOPOLOGY=1 ./scripts/build-dmg.sh`. That mode is
CI-only and ad-hoc signed, but it exercises the production product name,
permanent bundle identifier, Release configuration, archive layout, and DMG
name. It is structural coverage only; it cannot substitute for Developer ID,
notarization, Gatekeeper, or the release-time offline-recognition gate.

The build signs nested Sparkle components from the inside out, then the Tauri
application, submits the DMG for notarization, staples the ticket, and verifies
Gatekeeper acceptance. It then mounts that exact read-only DMG and verifies the
app name, production bundle identifier, version, build, feed URL, permanent
public key, minimum macOS version, signatures, entitlements, architectures,
and resources. Finally, the shipping Rust recognizer loads the installed model
and recognizes a synthetic fixture while an OS sandbox denies all network
access. Only after those checks does the
script sign the same DMG with Sparkle EdDSA and update `docs/appcast.xml`.

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
4. The Rust recognizer returns the expected fixture with `network*` denied by
   the OS and the process-attributed tracer observes zero network calls.
5. The main landing at `https://waiwai.is/ramble` shows this version and build
   and downloads the same DMG.
6. An older installed build can discover and install the update through
   Sparkle; the Tauri build’s native Sparkle UI can read the live feed.
