#!/bin/bash
# Ship: one command from a landed commit to a live update feed.
#
# `release.sh` builds, signs, notarizes and writes the feed entry, and then
# prints four things to do by hand: create the GitHub release, upload the
# image, commit the feed, check that it went live. Those four steps are where
# releases die. 0.11.1 was built and version-bumped and never existed for
# anyone: the tail was never run, and nothing anywhere said so — the feed kept
# serving 0.11.0 and looked healthy doing it.
#
# So the tail is not advice here. It runs, and the run ends with the live feed
# fetched from the internet and read. Either this script prints that the
# version is live, or it fails; there is no third ending in which a release
# half-happened and everyone assumed otherwise.
#
# Run from anywhere in the repository:
#
#   ./scripts/ship.sh
#   ./scripts/ship.sh --dry-run   # everything except the irreversible steps
#
# Everything else — which worktree to build in, where the keys are, which
# model root the release suites need — this script works out. Those were facts
# you had to already know, and a fact you have to already know is a fact that
# is lost the day nobody remembers it.

set -euo pipefail

REPO_SLUG="mikwiseman/openramble"
FEED_URL="https://mikwiseman.github.io/openramble/appcast.xml"
# main lives here permanently: the main checkout has its own branch, so it
# cannot check out main, and a release must be built from main.
RELEASE_WORKTREE="$HOME/Documents/Code/.worktrees/openramble-release"
SPARKLE_KEY_DEFAULT="$HOME/.openramble/sparkle-key"
# The release suites dictate for real and need a model. The default root is
# kept deliberately empty on this machine so a from-scratch install can be
# tested, so the release gets its own copy.
MODELS_ROOT_DEFAULT="$HOME/.openramble/release-models"
DEVELOPER_ID_DEFAULT="Developer ID Application: WaiWai, LLC (R4A779QVVY)"
# How long to wait for GitHub Pages to serve the new feed. It is normally under
# a minute; past five the publish did not take and saying so is the point.
FEED_TIMEOUT_SECONDS=300

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

say() { printf '\033[1m→ %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

# --- The tree to build from ------------------------------------------------

[[ -d "$RELEASE_WORKTREE" ]] || fail "No release worktree at $RELEASE_WORKTREE.
Create it once:
  git worktree add \"$RELEASE_WORKTREE\" main"

cd "$RELEASE_WORKTREE"
[[ -z "$(git status --porcelain)" ]] \
  || fail "The release worktree has uncommitted changes. It builds published
artifacts and must hold nothing but main:
  git -C \"$RELEASE_WORKTREE\" status"

say "Bringing the release worktree to origin/main"
git fetch --quiet origin main
git checkout --quiet main
git merge --ff-only --quiet origin/main

SHA=$(git rev-parse HEAD)
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' apps/macos/project.yml | head -1)
[[ -n "$VERSION" ]] || fail "No MARKETING_VERSION in apps/macos/project.yml."
NOTES="docs/release-notes/$VERSION.md"

# A release nobody can read about is half a release.
[[ -f "$NOTES" ]] || fail "No release notes at $NOTES.
Write them, land them on main, and ship again."

# The one check that cannot be recovered from afterwards: a tag that already
# exists means this version was published, and republishing it would hand a
# different binary to everyone who already has the old one under the same name.
if git ls-remote --exit-code --tags origin "v$VERSION" >/dev/null 2>&1; then
  fail "v$VERSION is already tagged on the remote.
Bump MARKETING_VERSION in apps/macos/project.yml, land it, and ship again."
fi

say "Shipping $VERSION (build from ${SHA:0:7})"

# --- The credentials, resolved rather than remembered ----------------------

SPARKLE_KEY_PATH="${SPARKLE_KEY_PATH:-$SPARKLE_KEY_DEFAULT}"
[[ -f "$SPARKLE_KEY_PATH" ]] || fail "No Sparkle key at $SPARKLE_KEY_PATH.
This key is permanent and is never regenerated — find it, do not make one:
  scripts/bootstrap-release-secrets.sh"

# This machine has no offline release keychain, so signing runs in legacy mode
# and needs the identity named outright.
DEVELOPER_ID="${DEVELOPER_ID:-$DEVELOPER_ID_DEFAULT}"
security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEVELOPER_ID" \
  || fail "The signing identity is not in the keychain:
  $DEVELOPER_ID
Check what is there with: security find-identity -v -p codesigning"

WAI_MODELS_ROOT="${WAI_MODELS_ROOT:-$MODELS_ROOT_DEFAULT}"
[[ -n "$(find "$WAI_MODELS_ROOT" -name '*.gguf' -print -quit 2>/dev/null)" ]] \
  || fail "No model under $WAI_MODELS_ROOT.
The release dictates for real and cannot do it without one:
  asr-bench import <dir with parakeet-tdt-0.6b-v3-Q8_0.gguf>"

if $DRY_RUN; then
  say "Dry run: everything above is what a real ship would have checked"
  echo "  version      $VERSION"
  echo "  commit       $SHA"
  echo "  notes        $NOTES"
  echo "  sparkle key  $SPARKLE_KEY_PATH"
  echo "  identity     $DEVELOPER_ID"
  echo "  models       $WAI_MODELS_ROOT"
  echo "  feed         $FEED_URL"
  exit 0
fi

# --- Build, sign, notarize -------------------------------------------------

# Not piped. A pipeline reports the exit code of its last command, so
# `release.sh | tail` reports tail's success no matter how the release ended —
# which is exactly how a refusal to build reads as a release that worked.
say "Building, signing and notarizing (15-25 minutes)"
SPARKLE_KEY_PATH="$SPARKLE_KEY_PATH" \
DEVELOPER_ID="$DEVELOPER_ID" \
WAI_MODELS_ROOT="$WAI_MODELS_ROOT" \
  ./scripts/release.sh

DMG="artifacts/dmg/OpenRamble-$VERSION.dmg"
[[ -f "$DMG" ]] || fail "release.sh finished but produced no image at $DMG."

# The feed entry release.sh wrote must actually be for this version, or the
# publish below would upload one thing and advertise another.
grep -qF "<title>$VERSION</title>" docs/appcast.xml \
  || fail "docs/appcast.xml does not carry $VERSION after the build."

# --- Publish ---------------------------------------------------------------

# The image goes up before the feed that points at it: for the minute in
# between, an update that does not exist yet is better than one that 404s.
say "Creating release v$VERSION and uploading the image"
gh release create "v$VERSION" "$DMG" \
  --repo "$REPO_SLUG" \
  --title "$VERSION" \
  --notes-file "$NOTES"

say "Publishing the feed"
git add docs/appcast.xml "$NOTES"
git commit --quiet -m "release: $VERSION

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push --quiet origin main

# --- The part that was missing --------------------------------------------

say "Waiting for the live feed to serve $VERSION"
deadline=$((SECONDS + FEED_TIMEOUT_SECONDS))
live=""
while (( SECONDS < deadline )); do
  live=$(curl -sSf "$FEED_URL" 2>/dev/null \
    | grep -oE '<title>[0-9]+\.[0-9]+\.[0-9]+</title>' | head -1 \
    | sed 's/<[^>]*>//g') || true
  [[ "$live" == "$VERSION" ]] && break
  sleep 15
done

[[ "$live" == "$VERSION" ]] || fail "The feed still serves ${live:-nothing} after
$((FEED_TIMEOUT_SECONDS / 60)) minutes. The release and the image are published;
the feed is not reaching people. Check GitHub Pages for $REPO_SLUG."

# And that the image the feed names is really there. A feed pointing at a
# missing file updates nobody and reports nothing.
DMG_URL=$(curl -sSf "$FEED_URL" | grep -oE 'url="[^"]+\.dmg"' | head -1 | sed 's/url="//;s/"//')
# Given a minute, because a freshly uploaded asset takes a few seconds to
# become fetchable. Checked once, this reported a perfectly good release as
# broken — a check that cries wolf gets ignored, which costs more than not
# having it.
image_deadline=$((SECONDS + 60))
until curl -sSfI -L "$DMG_URL" >/dev/null 2>&1; do
  (( SECONDS < image_deadline )) || fail "The feed serves $VERSION but its image is unreachable
after a minute of trying:
  $DMG_URL"
  sleep 5
done

printf '\n\033[32m%s is live. The feed serves it and its image downloads.\033[0m\n' "$VERSION"
echo "  $FEED_URL"
echo "  $DMG_URL"
