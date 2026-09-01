#!/usr/bin/env bash
#
# restore-models.sh — reproducibly materialise the on-device CoreML models
# into the exact tools/models/ layout that Scripts/build-app.sh expects, WITHOUT
# committing large binaries to git.
#
# The .mlpackage CoreML files are NOT committed. Two paths produce them:
#   - open-ogma-* and all-MiniLM-L6-v2 (download-on-demand tiers; restored here for the test
#     suite and models.yml): download the PyTorch source via tools/_dl.py (→ tools/models/<name>/)
#     and convert with tools/convert_ogma_libre.py / tools/convert_minilm.py
#     (→ tools/models/<name>.mlpackage, with a parity check)
#   - openvision-tiny-p8-{image,text} (the ONLY models the app BUNDLES): NOT converted here.
#     One pinned zip (both towers + the text tokenizer folder + manifest, built by
#     tools/convert_openvision.py + tools/pack-openvision.sh) is downloaded from the models-v1
#     GitHub release, SHA-256-verified against OPENVISION_ZIP_SHA256 below, and unpacked.
#
# Result for each <name> in MODELS, exactly what build-app.sh consumes:
#   tools/models/<name>.mlpackage
#   tools/models/<name>/{tokenizer.json,tokenizer_config.json,config.json}
#
# Idempotent: a model is skipped if its .mlpackage + tokenizer.json already exist
# (so a restored CI cache is reused for free).
#
# Requirements (install once before running):
#   pip install torch transformers coremltools sentencepiece safetensors huggingface_hub
# Python 3.10 is fine — tools/_compat.py provides the StrEnum shim ogma needs.
#
# Usage:
#   tools/restore-models.sh                      # restore the default set
#   MODELS="open-ogma-micro" tools/restore-models.sh  # restore a subset
#   HF_REPO_PREFIX=axiotic tools/restore-models.sh
#
# NOTE: the open-ogma (ogma-libre) models are MIT-licensed, distilled from
# BAAI/bge-small-en-v1.5 and bge-large-en-v1.5 (both MIT).
set -euo pipefail

cd "$(dirname "$0")"            # operate from tools/, like the README examples
ROOT="$(cd .. && pwd)"

# Default set of models to restore: everything a build or the test suite can consume.
# Keep in sync with Scripts/build-app.sh (BUNDLE_MODELS = the openvision pair) and
# Sources/Cliphoard/Search/DeepSearch.swift (low → open-ogma-micro, normal → open-ogma-small).
# embeddinggemma-300m is deliberately absent: that tier was retired on licensing
# grounds (see THIRD-PARTY-NOTICES.md). Passing MODELS= explicitly still fetches it
# for conversion work, but no default path pulls Gemma-licensed weights any more.
MODELS="${MODELS:-open-ogma-micro open-ogma-small all-MiniLM-L6-v2 openvision-tiny-p8-image openvision-tiny-p8-text}"
HF_REPO_PREFIX="${HF_REPO_PREFIX:-axiotic}"

# The bundled OpenVision pair: one pinned zip on the models-v1 release. Nothing at runtime
# downloads these (CLIPEmbedder loads them from the bundle only), so there is no ModelAssets
# pin to fall back on — this line IS the pin. Recompute with tools/pack-openvision.sh and
# re-upload whenever the towers are re-converted.
OPENVISION_ZIP_URL="${OPENVISION_ZIP_URL:-https://github.com/AntreasAntoniou/cliphoard/releases/download/models-v1/openvision-tiny-p8.zip}"
OPENVISION_ZIP_SHA256="c137d2f76e9ed583488cf5e5955f11d173192c05ccae4daa922e8ab6fdfb772a"

restore_openvision() {
    local zip="models/openvision-tiny-p8.zip" got
    echo "▸ Downloading $OPENVISION_ZIP_URL …"
    curl -fsSL --retry 3 -o "$zip" "$OPENVISION_ZIP_URL"
    got="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
    if [ "$got" != "$OPENVISION_ZIP_SHA256" ]; then
        rm -f "$zip"
        echo "::error::openvision-tiny-p8.zip sha256 $got != pinned $OPENVISION_ZIP_SHA256 — refusing to unpack" >&2
        exit 1
    fi
    /usr/bin/ditto -x -k "$zip" models/
    rm -f "$zip"
}

mkdir -p models

for name in $MODELS; do
    pkg="models/$name.mlpackage"
    case "$name" in
        openvision-tiny-p8-image) tok="" ;;                  # the image tower has no tokenizer
        *) tok="models/$name/tokenizer.json" ;;
    esac
    if [ -d "$pkg" ] && { [ -z "$tok" ] || [ -f "$tok" ]; }; then
        echo "▸ $name already present — skipping"
        continue
    fi

    echo "▸ Restoring $name …"
    case "$name" in
        open-ogma-*)
            repo="$HF_REPO_PREFIX/$name"
            echo "▸ Downloading $repo (PyTorch source) …"
            python3 _dl.py "$repo"
            python3 convert_ogma_libre.py "models/$name" ;;   # self-contained ogma-libre repos
        all-MiniLM-L6-v2)
            python3 convert_minilm.py ;;                      # pulls from HF cache itself
        embeddinggemma-300m)
            python3 convert_gemma.py ;;                       # gated: needs HF login w/ access
        openvision-tiny-p8-*)
            restore_openvision ;;                             # one pinned zip: both towers + tokenizer
        *)
            repo="$HF_REPO_PREFIX/$name"
            echo "▸ Downloading $repo (PyTorch source) …"
            python3 _dl.py "$repo"
            python3 convert_ogma.py "models/$name" ;;         # legacy HF trust_remote_code repos
    esac

    [ -d "$pkg" ] || { echo "::error::restore produced no $pkg" >&2; exit 1; }
    if [ -n "$tok" ] && [ ! -f "$tok" ]; then
        echo "::error::$name has no $tok (build-app.sh needs it)" >&2
        exit 1
    fi
    if [ "$name" = "openvision-tiny-p8-text" ] && [ ! -f "models/$name/config.json" ]; then
        echo "::error::$name has no config.json — swift-transformers' AutoTokenizer throws without it and image search is silently dark" >&2
        exit 1
    fi
done

echo "✓ Models restored under $ROOT/tools/models:"
ls -1d models/*.mlpackage 2>/dev/null || true
