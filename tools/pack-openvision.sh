#!/usr/bin/env bash
# pack-openvision.sh — build the ONE release asset that carries everything build-app.sh needs
# to bundle OpenVision-Tiny: both CoreML towers, the text tokenizer folder (incl. config.json)
# and the conversion manifest. tools/restore-models.sh downloads this zip from the models-v1
# release and verifies it against OPENVISION_ZIP_SHA256; re-run this, re-upload, re-pin
# whenever the towers are re-converted.
#
# Usage: tools/pack-openvision.sh [source-dir=tools/models] [out=<source-dir>/openvision-tiny-p8.zip]
set -euo pipefail
SIG="openvision-tiny-p8"
SRC="${1:-$(cd "$(dirname "$0")" && pwd)/models}"
OUT="${2:-$SRC/$SIG.zip}"
for p in "$SIG-image.mlpackage" "$SIG-text.mlpackage" "$SIG-text" "$SIG-manifest.json"; do
    [ -e "$SRC/$p" ] || { echo "::error::$SRC/$p missing — nothing to pack" >&2; exit 1; }
done
for f in tokenizer.json tokenizer_config.json special_tokens_map.json vocab.txt config.json; do
    [ -f "$SRC/$SIG-text/$f" ] || { echo "::error::$SRC/$SIG-text/$f missing" >&2; exit 1; }
done
STAGE="$(mktemp -d "$SRC/.pack-$SIG.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
for p in "$SIG-image.mlpackage" "$SIG-text.mlpackage" "$SIG-text" "$SIG-manifest.json"; do
    /usr/bin/ditto --norsrc --noextattr "$SRC/$p" "$STAGE/$p"
done
find "$STAGE" -name .DS_Store -delete
rm -f "$OUT"
/usr/bin/ditto -c -k --norsrc --noextattr "$STAGE" "$OUT"
echo "packed $OUT"
unzip -l "$OUT"
shasum -a 256 "$OUT"
