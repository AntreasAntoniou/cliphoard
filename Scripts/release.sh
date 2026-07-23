#!/usr/bin/env bash
#
# release.sh — build, Developer-ID sign, notarize, staple, and package Cliphoard as a
# distributable DMG. Designed to be runnable TODAY (it degrades gracefully to a
# self-signed local DMG) and to "just work" once you have an Apple Developer ID.
#
# One-time setup (needs an Apple Developer Program membership):
#   1. In Xcode > Settings > Accounts, create a "Developer ID Application" cert,
#      or download it from developer.apple.com. Find its name:
#         security find-identity -p codesigning -v | grep "Developer ID Application"
#   2. Store a notarization profile in your keychain (no password in this script):
#         xcrun notarytool store-credentials cliphoard-notary \
#            --apple-id "you@example.com" --team-id "ABCDE12345"
#      (use an app-specific password from appleid.apple.com)
#
# Then release with:
#   DEVID="Developer ID Application: Your Name (ABCDE12345)" \
#   NOTARY_PROFILE="cliphoard-notary" \
#   bash Scripts/release.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }

# Publish guard: the Homebrew cask ships an all-zero PLACEHOLDER sha256 that is
# meant to be replaced with the RELEASED DMG's sha256 at release time (this
# script packages the DMG; CI's "Compute DMG checksum" step prints that hash —
# see .github/workflows/release.yml). Refuse to cut a release while the cask
# still carries the placeholder, so a zero-sha (= unverifiable) install can never
# be published. A real (non-zero) sha passes this check untouched. Set
# ALLOW_PLACEHOLDER_SHA=1 only for a deliberate dry run that won't be published.
CASK="Casks/cliphoard.rb"
ZERO_SHA="0000000000000000000000000000000000000000000000000000000000000000"
if [[ -f "$CASK" ]] && grep -q "sha256 \"$ZERO_SHA\"" "$CASK"; then
    if [[ "${ALLOW_PLACEHOLDER_SHA:-}" == "1" ]]; then
        warn "$CASK still has the all-zero placeholder sha256 (ALLOW_PLACEHOLDER_SHA=1 — dry run only, DO NOT publish)."
    else
        printf '\033[1;31m✗ %s\033[0m\n' "$CASK still has the all-zero placeholder sha256." >&2
        printf '   %s\n' "Fill it with the released DMG's sha256 before releasing (CI prints it; see release.yml)." >&2
        printf '   %s\n' "For a deliberate non-publishing dry run, set ALLOW_PLACEHOLDER_SHA=1." >&2
        exit 1
    fi
fi

# A public release must never ship the old brand name. Sweep any leftover
# wrong-brand artifacts so no Ditto-named file can sit alongside the Cliphoard DMG.
rm -rf build/Ditto.app build/Ditto-*.dmg

APP="build/Cliphoard.app"
ENTITLEMENTS="Scripts/Cliphoard.entitlements"
DEVID="${DEVID:-}"                 # Developer ID Application identity (empty = local/self-signed)
NOTARY_PROFILE="${NOTARY_PROFILE:-}"   # notarytool keychain profile (empty = skip notarization)

# 1. Ensure the DEFAULT-tier models exist (restore if missing), then build a
# LEAN app: ogma micro/small + MiniLM bundled (~65MB of models); EmbeddingGemma
# (294MB) auto-downloads on demand from the models-v1 release. A release without
# the default models would ship "basic matching only" — hard-fail instead.
say "Restoring default-tier models…"
MODELS="open-ogma-micro open-ogma-small all-MiniLM-L6-v2" bash tools/restore-models.sh
for m in open-ogma-micro open-ogma-small all-MiniLM-L6-v2; do
    [ -d "tools/models/$m.mlpackage" ] || { echo "::error::missing model $m — release aborted" >&2; exit 1; }
done
say "Building Cliphoard.app…"
BUNDLE_MODELS="open-ogma-micro open-ogma-small all-MiniLM-L6-v2" bash Scripts/build-app.sh release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
say "Version $VERSION"

# 2. Developer ID signing with the Hardened Runtime (required for notarization).
if [[ -n "$DEVID" ]]; then
    say "Signing with Developer ID + Hardened Runtime…"
    # Cliphoard is a single Mach-O (static SwiftPM binary); .mlmodelc are data, not code.
    codesign --force --options runtime --timestamp \
             --entitlements "$ENTITLEMENTS" \
             --sign "$DEVID" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    say "Gatekeeper assessment:"
    spctl --assess --type execute --verbose=4 "$APP" || warn "spctl will pass only AFTER notarization."
else
    warn "DEVID not set — using the existing local/self-signed signature."
    warn "The resulting DMG is fine for local testing but NOT distributable"
    warn "(users would see an 'unidentified developer' / 'damaged' warning)."
fi

# 3. Notarize + staple (only meaningful with a Developer ID signature).
if [[ -n "$NOTARY_PROFILE" && -n "$DEVID" ]]; then
    say "Notarizing (this can take a few minutes)…"
    /usr/bin/ditto -c -k --keepParent "$APP" "build/Cliphoard.zip"
    xcrun notarytool submit "build/Cliphoard.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    say "Stapling ticket…"
    xcrun stapler staple "$APP"
    rm -f "build/Cliphoard.zip"
elif [[ -n "$DEVID" ]]; then
    warn "NOTARY_PROFILE not set — skipping notarization (DMG won't pass Gatekeeper)."
fi

# 4. Package a drag-to-Applications DMG.
say "Building DMG…"
DMG="build/Cliphoard-$VERSION.dmg"
STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Cliphoard.app"
# Ship the license + attribution next to the app so a user who mounts the DMG
# sees them (the bundled CC-BY-NC ogma models require this on redistribution).
cp "LICENSE" "$STAGE/"
cp "THIRD-PARTY-NOTICES.md" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Cliphoard $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# 5. Sign + notarize the DMG itself (recommended for direct distribution).
if [[ -n "$DEVID" ]]; then
    codesign --force --timestamp --sign "$DEVID" "$DMG"
    if [[ -n "$NOTARY_PROFILE" ]]; then
        say "Notarizing DMG…"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

say "Done → $DMG"
[[ -z "$DEVID" ]] && warn "Set DEVID + NOTARY_PROFILE for a distributable build (see header)."
exit 0
