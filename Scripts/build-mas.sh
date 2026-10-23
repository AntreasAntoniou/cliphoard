#!/usr/bin/env bash
# Assemble Cliphoard for Mac App Store review. Does not create certificates, profiles,
# App Store Connect records, uploads, or purchases.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${MAS_CONFIG:-release}"
MODE="${MAS_SIGN_MODE:-adhoc}"       # adhoc | app-store
OUT="${MAS_OUTPUT_DIR:-$ROOT/build/mas}"
SCRATCH="${MAS_SCRATCH_PATH:-$ROOT/build/mas-swiftpm}"
APP="$OUT/Cliphoard.app"
PKG="$OUT/Cliphoard.pkg"
ENTITLEMENTS="$ROOT/Scripts/Cliphoard-MAS.entitlements"
PRIVACY_MANIFEST="$ROOT/Resources/PrivacyInfo.xcprivacy"
BUNDLE_ID="ai.a2-labs.cliphoard"
TEAM_ID="${MAS_TEAM_ID:-74M96PGT6P}"

case "$MODE" in
    adhoc|app-store) ;;
    *) echo "ERROR: MAS_SIGN_MODE must be adhoc or app-store" >&2; exit 2 ;;
esac
test -f "$PRIVACY_MANIFEST" || {
    echo "ERROR: Resources/PrivacyInfo.xcprivacy is required for the Store package" >&2
    exit 3
}
plutil -lint "$PRIVACY_MANIFEST" >/dev/null

ARCH_ARGS=()
for arch in ${MAS_ARCHS:-arm64 x86_64}; do ARCH_ARGS+=(--arch "$arch"); done
BUILD_ARGS=(-c "$CONFIG" --scratch-path "$SCRATCH" "${ARCH_ARGS[@]}" -Xswiftc -DAPP_STORE)

echo "▸ Compiling APP_STORE ($CONFIG) in isolated scratch path…"
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" "${ARCH_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/Cliphoard"
test -x "$BIN" || { echo "ERROR: missing compiled Cliphoard binary" >&2; exit 4; }
if nm -u "$BIN" | grep -Eq 'AXIsProcessTrusted|CGEvent(CreateKeyboardEvent|Post)'; then
    echo "ERROR: APP_STORE binary still links an Accessibility or synthetic-input path" >&2
    exit 5
fi
if strings "$BIN" | grep -E 'axiotic/open-ogma|releases/download/models-v1' >/dev/null; then
    echo "ERROR: APP_STORE binary still contains a direct model-download endpoint" >&2
    exit 5
fi

echo "▸ Assembling Store bundle…"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cliphoard"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
if /usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Set :LSApplicationCategoryType public.app-category.productivity' "$APP/Contents/Info.plist"
else
    /usr/libexec/PlistBuddy -c 'Add :LSApplicationCategoryType string public.app-category.productivity' "$APP/Contents/Info.plist"
fi
# The Store build does not automate another app and has no Accessibility prompt.
/usr/libexec/PlistBuddy -c 'Delete :NSAppleEventsUsageDescription' "$APP/Contents/Info.plist" >/dev/null 2>&1 || true

if command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
    ICONSET="$OUT/Cliphoard.iconset"
    mkdir -p "$ICONSET"
    for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
                128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
                512:icon_512x512 1024:icon_512x512@2x; do
        sips -z "${spec%%:*}" "${spec%%:*}" "$ROOT/Resources/AppIcon.png" \
             --out "$ICONSET/${spec##*:}.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Cliphoard.icns"
    rm -rf "$ICONSET"
fi

# Store review sees every feature that ships. Bundle every reachable model tier so the app
# does not fetch functionality after review. EmbeddingGemma is retired and forbidden here.
MAS_BUNDLE_MODELS="${MAS_BUNDLE_MODELS:-open-ogma-micro open-ogma-small all-MiniLM-L6-v2 openvision-tiny-p8-image openvision-tiny-p8-text}"
case " $MAS_BUNDLE_MODELS " in *" embeddinggemma-300m "*)
    echo "ERROR: retired restricted EmbeddingGemma must not enter the Store bundle" >&2; exit 6;;
esac
for name in $MAS_BUNDLE_MODELS; do
    pkg="$ROOT/tools/models/$name.mlpackage"
    test -d "$pkg" || { echo "ERROR: required Store model missing: $pkg" >&2; exit 7; }
    xcrun coremlcompiler compile "$pkg" "$APP/Contents/Resources" >/dev/null
    src="$ROOT/tools/models/$name"
    if [ -f "$src/tokenizer.json" ]; then
        dst="$APP/Contents/Resources/$name-tokenizer"
        mkdir -p "$dst"
        for file in tokenizer.json tokenizer_config.json config.json special_tokens_map.json; do
            [ ! -f "$src/$file" ] || cp "$src/$file" "$dst/"
        done
        case "$name" in *ogma*)
            python3 -c "import json; p='$dst/tokenizer_config.json'; d=json.load(open(p)); d['tokenizer_class']='T5Tokenizer'; json.dump(d,open(p,'w'))"
        esac
    fi
done

cp "$ROOT/LICENSE" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE-Apache-2.0.txt" "$APP/Contents/Resources/"
cp "$ROOT/THIRD-PARTY-NOTICES-MAS.md" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
cp "$PRIVACY_MANIFEST" "$APP/Contents/Resources/"

STRICT_BUNDLE=1 BUNDLE_MODELS="$MAS_BUNDLE_MODELS" \
    NOTICE_SOURCE="$ROOT/THIRD-PARTY-NOTICES-MAS.md" \
    CHECKOUTS_DIR="$SCRATCH/checkouts" \
    bash "$ROOT/Scripts/verify-bundle.sh" "$APP" "$ROOT"

EXPANDED="$(mktemp -t cliphoard-mas-entitlements).plist"
PROFILE_PLIST="$(mktemp -t cliphoard-mas-profile).plist"
cleanup() { rm -f "$EXPANDED" "$PROFILE_PLIST"; }
trap cleanup EXIT

if [ "$MODE" = adhoc ]; then
    sed -e "s/\$(AppIdentifierPrefix)/$TEAM_ID./g" \
        -e "s/\$(TeamIdentifierPrefix)/$TEAM_ID/g" "$ENTITLEMENTS" > "$EXPANDED"
    plutil -lint "$EXPANDED" >/dev/null
    # Restricted application/keychain identifiers require a matching profile. Remove them
    # only from this local inspection signature; the app-store mode below refuses to do so.
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.application-identifier' "$EXPANDED"
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.team-identifier' "$EXPANDED"
    /usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups' "$EXPANDED"
    codesign --force --sign - --entitlements "$EXPANDED" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    rm -f "$PKG"
    echo "✓ Assembled local sandbox inspection app: $APP"
    echo "  Not uploadable: rerun with MAS_SIGN_MODE=app-store plus profile and identities."
    exit 0
fi

: "${MAS_PROFILE:?Set MAS_PROFILE to the Mac App Store Connect provisioning profile}"
: "${MAS_APP_IDENTITY:?Set MAS_APP_IDENTITY to the Mac App Distribution signing identity}"
: "${MAS_INSTALLER_IDENTITY:?Set MAS_INSTALLER_IDENTITY to the Mac Installer Distribution identity}"
test -f "$MAS_PROFILE" || { echo "ERROR: MAS_PROFILE does not exist" >&2; exit 9; }
security cms -D -i "$MAS_PROFILE" > "$PROFILE_PLIST"
APP_PREFIX="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationIdentifierPrefix:0' "$PROFILE_PLIST")"
test -n "$APP_PREFIX" || { echo "ERROR: profile has no App ID prefix" >&2; exit 10; }
sed -e "s/\$(AppIdentifierPrefix)/$APP_PREFIX./g" \
    -e "s/\$(TeamIdentifierPrefix)/$TEAM_ID/g" "$ENTITLEMENTS" > "$EXPANDED"
plutil -lint "$EXPANDED" >/dev/null
python3 "$ROOT/Scripts/verify-mas-profile.py" profile \
    --profile-plist "$PROFILE_PLIST" --intended-entitlements "$EXPANDED" \
    --bundle-id "$BUNDLE_ID" --team-id "$TEAM_ID"
cp "$MAS_PROFILE" "$APP/Contents/embedded.provisionprofile"

codesign --force --timestamp --sign "$MAS_APP_IDENTITY" --entitlements "$EXPANDED" "$APP"
python3 "$ROOT/Scripts/verify-mas-profile.py" signed \
    --profile-plist "$PROFILE_PLIST" --intended-entitlements "$EXPANDED" \
    --bundle-id "$BUNDLE_ID" --team-id "$TEAM_ID" --app "$APP"

rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$MAS_INSTALLER_IDENTITY" "$PKG"
pkgutil --check-signature "$PKG"
echo "✓ Built signed Mac App Store upload package: $PKG"
