#!/bin/bash
# Publishes the Windows and Linux packages as a GitHub release.
#
# The macOS app has its own release process with signing, notarisation and a
# Sparkle appcast (docs/release.md). This is deliberately separate and much
# smaller: these packages are unsigned today, and pretending otherwise by
# reusing the Mac's machinery would hide that.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: $0 <version>   e.g. $0 0.1.0" >&2; exit 64; }

TAG="desktop-v$VERSION"
NOTES="docs/release-notes/desktop-$VERSION.md"
[[ -f "$NOTES" ]] || { echo "No release notes at $NOTES" >&2; exit 1; }

# The packages come from a completed run of the packaging workflow, so what is
# published is exactly what CI built rather than whatever is on this machine.
RUN=$(gh run list --workflow=desktop-release.yml --status=success --limit 1 \
        --json databaseId --jq '.[0].databaseId')
[[ -n "$RUN" ]] || { echo "No successful packaging run to publish." >&2; exit 1; }

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
gh run download "$RUN" --dir "$STAGING"

FILES=()
while IFS= read -r file; do FILES+=("$file"); done < <(find "$STAGING" -type f \
  \( -name "*.msi" -o -name "*.exe" -o -name "*.AppImage" -o -name "*.deb" -o -name "*.rpm" \))
[[ ${#FILES[@]} -gt 0 ]] || { echo "That run produced no packages." >&2; exit 1; }

echo "Publishing $TAG from run $RUN:"
printf '  %s\n' "${FILES[@]##*/}"

gh release create "$TAG" "${FILES[@]}" \
  --title "OpenRamble for Windows and Linux $VERSION" \
  --notes-file "$NOTES" \
  --latest=false

echo "Published: $(gh release view "$TAG" --json url --jq .url)"
