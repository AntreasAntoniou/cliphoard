#!/usr/bin/env bash
# Builds Ditto.app — a self-contained macOS application bundle.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Ditto.app"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG" 2>/dev/null
BIN="$(swift build -c "$CONFIG" --show-bin-path 2>/dev/null)/Ditto"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ditto"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Icon (best effort — skipped if iconutil/sips unavailable).
if command -v iconutil >/dev/null 2>&1; then
    echo "▸ Rendering icon…"
    swift "$ROOT/Scripts/make-icon.swift" "$ROOT/build" >/dev/null 2>&1 || true
    if [ -d "$ROOT/build/Ditto.iconset" ]; then
        iconutil -c icns "$ROOT/build/Ditto.iconset" -o "$APP/Contents/Resources/Ditto.icns" 2>/dev/null || true
        rm -rf "$ROOT/build/Ditto.iconset"
    fi
fi

# Deep-search models (best effort). Compile any converted CoreML packages in
# tools/models to .mlmodelc and bundle them + their tokenizer so on-device
# embedding works. Absent → the app falls back to the built-in HashingEmbedder.
if ls "$ROOT"/tools/models/*.mlpackage >/dev/null 2>&1; then
    echo "▸ Bundling embedding models…"
    for pkg in "$ROOT"/tools/models/*.mlpackage; do
        name="$(basename "$pkg" .mlpackage)"
        xcrun coremlcompiler compile "$pkg" "$APP/Contents/Resources" 2>/dev/null \
            && echo "  • $name.mlmodelc"
        # bundle the tokenizer as a folder <name>-tokenizer/ with the two files
        # AutoTokenizer.from(modelFolder:) needs.
        src="$ROOT/tools/models/$name"
        if [ -f "$src/tokenizer.json" ]; then
            dst="$APP/Contents/Resources/$name-tokenizer"
            mkdir -p "$dst"
            cp "$src/tokenizer.json" "$dst/"
            [ -f "$src/tokenizer_config.json" ] && cp "$src/tokenizer_config.json" "$dst/"
            # swift-transformers' AutoTokenizer.from(modelFolder:) also reads config.json
            [ -f "$src/config.json" ] && cp "$src/config.json" "$dst/"
            # Remap the custom tokenizer_class to T5Tokenizer — swift-transformers'
            # Unigram implementation, which matches ogma's Unigram tokenizer.json.
            python3 -c "import json; p='$dst/tokenizer_config.json'; d=json.load(open(p)); d['tokenizer_class']='T5Tokenizer'; json.dump(d, open(p,'w'))" 2>/dev/null || true
        fi
    done
fi

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
    codesign --force --deep --sign "$SIGN_ID" "$APP" 2>/dev/null || echo "  (codesign skipped)"
else
    echo "▸ Signing (ad-hoc — run Scripts/setup-signing.sh for a stable identity)…"
    codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign skipped)"
fi

echo "✓ Built $APP"
