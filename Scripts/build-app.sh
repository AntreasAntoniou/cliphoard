#!/usr/bin/env bash
# Builds Cliphoard.app — a self-contained macOS application bundle.
set -euo pipefail
PYTHON="${CLIPHOARD_PYTHON:-/opt/homebrew/bin/python3.14}"
"$PYTHON" -c 'import sys; assert sys.version_info >= (3, 14), "Python 3.14+ required"'

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Cliphoard.app"
"$PYTHON" "$ROOT/Scripts/audit-no-models.py" --check-environment

echo "▸ Building ($CONFIG, universal arm64 + x86_64)…"
# Build a UNIVERSAL binary so the app runs natively on both Apple Silicon and Intel
# (an arm64-only build will not launch on Intel at all — Rosetta only runs x86 on ARM).
swift build -c "$CONFIG" --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path 2>/dev/null)"
BIN="$BIN_DIR/Cliphoard"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cliphoard"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Direct releases advance independently; the Store assembler keeps its own plist.
"$PYTHON" - "$ROOT/Resources/DirectBuild.txt" "$APP/Contents/Info.plist" <<'PYDIRECT'
import pathlib, plistlib, sys
build = pathlib.Path(sys.argv[1]).read_text().strip()
assert build.isascii() and build.isdigit() and int(build) > 0
path = pathlib.Path(sys.argv[2]); info = plistlib.loads(path.read_bytes())
info["CFBundleVersion"] = build
path.write_bytes(plistlib.dumps(info))
PYDIRECT
bash "$ROOT/Scripts/embed-media-runtime.sh" "$APP" "$BIN_DIR"
"$PYTHON" "$ROOT/Scripts/build-app-intents.py" --scratch "$ROOT/.build" --configuration "$CONFIG" --app "$APP"
# Icon (best effort). Built from the committed master PNG (the hoard-bag mascot,
# Resources/AppIcon.png); falls back to the vector make-icon.swift (⌘V) if absent.
if command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
    echo "▸ Rendering icon…"
    ICONSET="$ROOT/build/Cliphoard.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    if [ -f "$ROOT/Resources/AppIcon.png" ]; then
        for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
                    128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
                    512:icon_512x512 1024:icon_512x512@2x; do
            sips -z "${spec%%:*}" "${spec%%:*}" "$ROOT/Resources/AppIcon.png" \
                 --out "$ICONSET/${spec##*:}.png" >/dev/null 2>&1
        done
    else
        swift "$ROOT/Scripts/make-icon.swift" "$ROOT/build" >/dev/null 2>&1 || true
    fi
    if [ -d "$ICONSET" ]; then
        iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Cliphoard.icns" 2>/dev/null || true
        rm -rf "$ICONSET"
    fi
fi

# All model weights are downloaded and prepared locally after explicit user selection.
# Build output never depends on tools/models or a developer model cache.

# Licence + attribution. Ship them with the bundle so attribution travels with
# every redistribution. THIRD-PARTY-NOTICES.md is the SINGLE source of truth for
# what is bundled and what is linked — do not restate any of it here or in
# LICENSE. Two copies of that fact is what produced the CC-BY-NC defect.
# Apache-2.0 s4(a) requires recipients receive a copy of the licence: the
# runtime libraries linked into the binary are Apache-2.0, so naming the licence is not on its own sufficient.
echo "▸ Bundling license + attribution…"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE-Apache-2.0.txt" "$APP/Contents/Resources/"
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/"

"$PYTHON" "$ROOT/Scripts/audit-no-models.py" "$APP"

# Code-sign the bundle. Prefer the stable, self-signed "Ditto Local Signing"
# identity (created by Scripts/setup-signing.sh) so the macOS Accessibility grant
# survives rebuilds — macOS keys the AX grant to code identity, and a stable
# identity keeps it constant. If that identity is not present, fall back to ad-hoc
# (`-`), which mints a fresh identity each build and thus drops the AX grant on
# every rebuild (see SPEC Tier 6.6). Run Scripts/setup-signing.sh once to fix that.
# Note: no `-v` (valid-only) — a self-signed identity is reported NOT_TRUSTED and
# filtered by `-v`, yet codesign can still sign with it perfectly well.
SIGN_ID="Ditto Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    echo "▸ Signing (stable: $SIGN_ID)…"
    codesign --force --sign "$SIGN_ID" "$APP/Contents/Frameworks/libCLiteRTLM_mac.dylib"
    codesign --force --sign "$SIGN_ID" "$APP"
else
    echo "▸ Signing (ad-hoc — run Scripts/setup-signing.sh for a stable identity)…"
    codesign --force --sign - "$APP/Contents/Frameworks/libCLiteRTLM_mac.dylib"
    codesign --force --sign - "$APP"
fi

echo "✓ Built $APP"

# Prove the assembled bundle matches what the licence documents claim. This runs on
# EVERY build path (make app, deploy-local.sh, release.sh) because the .app is what
# reaches a user; unit tests alone do not inspect its final Resources directory.
bash "$ROOT/Scripts/verify-bundle.sh" "$APP" "$ROOT"
