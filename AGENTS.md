# Release secrets and publishing

Code conventions are documented in [CLAUDE.md](CLAUDE.md), and the build and
release process is documented in [docs/release.md](docs/release.md). This file
only describes release state that must not be stored in the repository.

## Sparkle private key

The Sparkle private key moves between trusted release machines. It belongs to
the product, not to an Apple account.

| Item | Value |
|---|---|
| Storage | 1Password, `Development` vault |
| Item ID | `mnt44t2qfcoavybwxokaqxx6se` |
| Secret reference | `op://Development/mnt44t2qfcoavybwxokaqxx6se/password` |
| Local path | `~/.openramble/sparkle-key`, mode `0600` |
| Public half | `SUPublicEDKey` in `apps/macos/project.yml` |

The public key is embedded in every distributed build. An installed copy will
only accept an update signed by the matching private key. Losing the private
key and generating another pair would permanently strand existing users.

Therefore, **never run `generate_keys` for this product**. If the key cannot be
found, recover the existing key instead of creating a new one.

The private key is deliberately stored outside the macOS login keychain so it
can be recovered after loss of a release machine.

## Preparing a release machine

```bash
./scripts/bootstrap-release-secrets.sh
```

The script validates an existing Sparkle key or restores it from 1Password,
then validates file-based App Store Connect credentials. It never prints key
contents or credential identifiers.

The machine must have `~/.appstoreconnect/config.json` and the selected `.p8`
under `~/.appstoreconnect/private_keys/`; both files must have mode `0600`.

## App Store Connect and Developer ID

Notarization normally uses an App Store Connect Team API key:

- config: `~/.appstoreconnect/config.json` with `key_filepath`, `key_id`, and
  `issuer_id`;
- key: `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`;
- both files use mode `0600`;
- recovery backup: 1Password `Development`, item ID
  `zavvctbf6g4el7ygzphjb7mvu4`.

Release scripts never read App Store Connect credentials directly from
1Password. Transfer them between trusted release machines through a secure
channel and verify them with `xcrun notarytool history --key ... --key-id ...
--issuer ...`.

A Developer ID Application certificate with its private key is also required.
It can be installed through Xcode or recovered from the archived `.p12`. Check
available identities with `security find-identity -v -p codesigning`.

Autonomous releases use a dedicated release keychain rather than the login
keychain:

| Item | Path |
|---|---|
| Keychain | `~/.openramble/release.keychain-db` |
| Keychain password | `~/.openramble/release-keychain-password` |
| Recovery identity | `~/.openramble/developer-id.p12` |
| `.p12` password | `~/.openramble/developer-id-export-password` |

All four files use mode `0600`. `scripts/bootstrap-release-secrets.sh` unlocks
the release keychain without a GUI, puts it first in the user search list, and
selects the Developer ID identity by fingerprint. If the keychain is missing,
the script can restore it from the encrypted `.p12` and password files.

## Release

```bash
SPARKLE_KEY_PATH="$HOME/.openramble/sparkle-key" \
./scripts/release.sh
```

The release script requires a clean `main` branch that matches `origin/main`
and has a successful CI run for the same commit. It validates release notes,
offline runtime behavior, the Developer ID signature, notarization, stapling,
Gatekeeper acceptance, and the exact Sparkle EdDSA signature of the DMG.

Live voice benchmarks and the manual release matrix may be collected as audit
evidence, but neither is a release requirement. Never fabricate results or
automatically replace missing evidence with `pass`.

## Application identifier

The bundle identifier `is.waiwai.dictation` is permanent because existing
macOS Accessibility permission grants are attached to it. Changing it would
force every user to grant permission again. `scripts/build-dmg.sh` enforces
this identifier.
