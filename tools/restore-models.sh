#!/usr/bin/env bash
#
# restore-models.sh — reproducibly materialise the on-device ogma CoreML models
# into the exact tools/models/ layout that Scripts/build-app.sh expects, WITHOUT
# committing large binaries to git.
#
# The .mlpackage CoreML files are NOT published; they are produced LOCALLY by
# converting the public PyTorch weights from HuggingFace. This script:
#   1. downloads each ogma repo's PyTorch source (weights + tokenizer + config)
#      via tools/_dl.py  (→ tools/models/<name>/)
#   2. converts it to CoreML via tools/convert_ogma.py
#      (→ tools/models/<name>.mlpackage, with a parity check)
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

# Default set of models to restore. Keep in sync with Scripts/build-app.sh /
# Sources/Cliphoard/Search/DeepSearch.swift (low → open-ogma-micro,
# normal → open-ogma-small).
MODELS="${MODELS:-open-ogma-micro open-ogma-small all-MiniLM-L6-v2 embeddinggemma-300m}"
HF_REPO_PREFIX="${HF_REPO_PREFIX:-axiotic}"

mkdir -p models

for name in $MODELS; do
    pkg="models/$name.mlpackage"
    tok="models/$name/tokenizer.json"
    if [ -d "$pkg" ] && [ -f "$tok" ]; then
        echo "▸ $name already present — skipping"
        continue
    fi

    echo "▸ Converting $name → CoreML …"
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
        *)
            repo="$HF_REPO_PREFIX/$name"
            echo "▸ Downloading $repo (PyTorch source) …"
            python3 _dl.py "$repo"
            python3 convert_ogma.py "models/$name" ;;         # legacy HF trust_remote_code repos
    esac

    if [ ! -d "$pkg" ]; then
        echo "::error::conversion produced no $pkg" >&2
        exit 1
    fi
    if [ ! -f "$tok" ]; then
        echo "::error::$repo did not ship tokenizer.json (build-app.sh needs it)" >&2
        exit 1
    fi
done

echo "✓ Models restored under $ROOT/tools/models:"
ls -1d models/*.mlpackage 2>/dev/null || true
