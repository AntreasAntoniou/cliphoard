#!/usr/bin/env bash
# publish-cask.sh — copy Casks/cliphoard.rb into a checkout of the Homebrew tap, refusing the
# all-zero placeholder sha256 and any sha that is not the published DMG's. This is where the
# "never publish a zero sha" gate lives, now that release.sh writes the real sha itself.
#
# Usage: Scripts/publish-cask.sh <path-to-homebrew-tap-checkout>
#   then commit + push inside the tap. Users: brew install --cask antreasantoniou/tap/cliphoard
set -euo pipefail
cd "$(dirname "$0")/.."
TAP="${1:?usage: publish-cask.sh <tap-checkout>}"
CASK="Casks/cliphoard.rb"
ZERO_SHA="0000000000000000000000000000000000000000000000000000000000000000"
V="$(sed -nE 's/^  version "([^"]+)"$/\1/p' "$CASK")"
SHA="$(sed -nE 's/^  sha256 "([0-9a-f]{64})"$/\1/p' "$CASK")"
[[ -n "$V" && -n "$SHA" ]] || { echo "✗ could not read version/sha256 from $CASK" >&2; exit 1; }
if [[ "$SHA" == "$ZERO_SHA" ]]; then
    echo "✗ $CASK still carries the all-zero placeholder sha256 — cut a release first (a tag push runs release.yml, which writes and commits the real sha)." >&2
    exit 1
fi
URL="https://github.com/AntreasAntoniou/cliphoard/releases/download/v$V/Cliphoard-$V.dmg"
mkdir -p build
echo "▸ Verifying $URL against the cask sha256 …"
curl -fsSL --retry 3 -o "build/publish-check-$V.dmg" "$URL" \
    || { echo "✗ $URL is not downloadable — is v$V published?" >&2; exit 1; }
GOT="$(shasum -a 256 "build/publish-check-$V.dmg" | cut -d' ' -f1)"
rm -f "build/publish-check-$V.dmg"
[[ "$GOT" == "$SHA" ]] || { echo "✗ published DMG sha256 $GOT != cask sha256 $SHA — the cask does not describe the released artifact" >&2; exit 1; }
mkdir -p "$TAP/Casks"
cp "$CASK" "$TAP/Casks/cliphoard.rb"
echo "✓ $TAP/Casks/cliphoard.rb written from $CASK (v$V, sha256 verified). Now: git -C $TAP add Casks/cliphoard.rb && git -C $TAP commit -m 'cliphoard $V' && git -C $TAP push"
