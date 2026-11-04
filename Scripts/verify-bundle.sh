#!/usr/bin/env bash
# Verify download-only bundle policy and unchanged licence distribution obligations.
# Usage: verify-bundle.sh APP REPO [DMG_STAGE]; NOTICE_SOURCE/CHECKOUTS_DIR select channel.
set -euo pipefail
PYTHON="${CLIPHOARD_PYTHON:-/opt/homebrew/bin/python3.14}"
"$PYTHON" -c 'import sys; assert sys.version_info >= (3, 14), "Python 3.14+ required"'

APP="${1:?usage: verify-bundle.sh <app> <repo-root> [stage-dir]}"
ROOT="${2:?}"
EXTRA="${3:-}"
RES="$APP/Contents/Resources"
NOTICE_SOURCE="${NOTICE_SOURCE:-$ROOT/THIRD-PARTY-NOTICES.md}"
CHECKOUTS_DIR="${CHECKOUTS_DIR:-$ROOT/.build/checkouts}"
fail=0
note() { printf '  %s %s\n' "$1" "$2"; }
bad()  { note "✗" "$1"; fail=1; }

echo "verify-bundle: $APP"
"$PYTHON" "$ROOT/Scripts/audit-no-models.py" "$APP"
[ -d "$RES" ] || { bad "no Contents/Resources — not an app bundle"; exit 1; }

# 1. Licence texts must physically reach the recipient, in every directory that is
#    itself a distribution channel (the .app, and the DMG staging root).
for dir in "$RES" ${EXTRA:+"$EXTRA"}; do
    for f in LICENSE LICENSE-Apache-2.0.txt; do
        if [ ! -f "$dir/$f" ]; then
            bad "$dir/$f is missing — a recipient gets the software without its licence"
        elif ! cmp -s "$dir/$f" "$ROOT/$f"; then
            bad "$dir/$f differs from the repository copy"
        fi
    done
    if [ ! -f "$dir/THIRD-PARTY-NOTICES.md" ]; then
        bad "$dir/THIRD-PARTY-NOTICES.md is missing — a recipient gets no third-party notices"
    elif ! cmp -s "$dir/THIRD-PARTY-NOTICES.md" "$NOTICE_SOURCE"; then
        bad "$dir/THIRD-PARTY-NOTICES.md differs from $NOTICE_SOURCE"
    fi
done

# 2. LICENSE must be canonical MIT, not merely identical to the repo copy: a repo LICENSE
#    with a prepended or appended clause would otherwise ship in every DMG. The body hash
#    is taken with the holder line (line 3)
#    masked, so a year bump passes and any other edit fails. The holder line is a SINGLE
#    year — no range — and the file is exactly 1073 bytes: DistributionLicenceTests
#    .testTheLicenceIsUnmodifiedMIT pins the same three facts, and the two guards must agree.
MIT_BODY_SHA256="ac483bb6267e16aac1620af5d09a1ccd94c3bbab762ac1b3ee391fe18021deae"
for dir in "$RES" ${EXTRA:+"$EXTRA"}; do
    [ -f "$dir/LICENSE" ] || continue
    got="$(sed '3s/.*/@HOLDER@/' "$dir/LICENSE" | shasum -a 256 | cut -d' ' -f1)"
    [ "$got" = "$MIT_BODY_SHA256" ] \
        || bad "$dir/LICENSE is not canonical MIT (masked-holder sha256 $got) — a prepended or appended clause ships to every recipient"
    sed -n 3p "$dir/LICENSE" | grep -Eq '^Copyright \(c\) [0-9]{4} Antreas Antoniou$' \
        || bad "$dir/LICENSE line 3 is not the plain single-year copyright line (a year range breaks the 1073-byte pin the Swift test holds)"
    size="$(wc -c < "$dir/LICENSE" | tr -d ' ')"
    [ "$size" -eq 1073 ] \
        || bad "$dir/LICENSE is ${size} bytes, not 1073 — canonical MIT with a single-year holder line"
done

# 3. LICENSE-Apache-2.0.txt must be the COMPLETE, canonical licence. Step 1 only proves the
#    app copy equals the repo copy, so a one-line stub in the repo would ship identically and
#    pass. Same landmarks and size floor as DistributionLicenceTests
#    .testTheApacheTextExistsAndBothBuildPathsShipIt, plus the
#    sha256 of apache.org's LICENSE-2.0.txt, pinned there as apacheSHA256.
APACHE_SHA256="cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
for dir in "$RES" ${EXTRA:+"$EXTRA"}; do
    f="$dir/LICENSE-Apache-2.0.txt"; [ -f "$f" ] || continue
    size="$(wc -c < "$f" | tr -d ' ')"
    [ "$size" -gt 9000 ] \
        || bad "$f is ${size} bytes — too short to be the complete Apache-2.0 text, so s4(a) is not discharged"
    for marker in "Apache License" "Version 2.0, January 2004" "4. Redistribution." \
                  "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION" \
                  "APPENDIX: How to apply the Apache License to your work."; do
        grep -qF -- "$marker" "$f" || bad "$f lacks '${marker}' — not the complete licence"
    done
    got="$(shasum -a 256 "$f" | cut -d' ' -f1)"
    [ "$got" = "$APACHE_SHA256" ] \
        || bad "$f is not the canonical apache.org LICENSE-2.0.txt (sha256 ${got}) — a reflowed or edited copy is not the licence"
done

# 4. Every MIT package linked into the binary (Jinja: `nm` finds its symbols) must have its
#    upstream LICENSE reproduced VERBATIM in the part of THIRD-PARTY-NOTICES.md a reader can
#    see. The distribution-manifest HTML comment carries the same copyright line, so a raw
#    grep stayed green with the entire visible Jinja section deleted. Strip comments, take
#    the text under the `### <name>` heading, require every non-blank upstream line in it.
VISIBLE="$(perl -0777 -pe 's/<!--.*?-->//gs' "$RES/THIRD-PARTY-NOTICES.md" 2>/dev/null || true)"
section_for() {   # $1 = lowercase needle that must appear in a `### ` heading
    awk -v n="$1" '/^### /{f=index(tolower($0),n)>0; next} /^## /{f=0} f' <<< "$VISIBLE"
}
linked_mit=0
while IFS= read -r line; do
    url="${line#linked:}"; url="${url%%|*}"; url="$(printf '%s' "$url" | xargs)"
    name="${url##*/}"; name="${name%.git}"
    up="$CHECKOUTS_DIR/$name/LICENSE"
    if [ ! -f "$up" ]; then
        bad "$name is declared linked (MIT) but $up is unreadable — cannot confirm its notice"
        continue
    fi
    section="$(section_for "$(printf '%s' "$name" | tr 'A-Z' 'a-z')")"
    [ -n "$section" ] || { bad "no VISIBLE '### $name' section in THIRD-PARTY-NOTICES.md (a manifest comment is not a notice a reader can see)"; continue; }
    while IFS= read -r want; do
        [ -n "$want" ] || continue
        grep -qxF -- "$want" <<< "$section" \
            || { bad "$name's visible section does not reproduce its upstream LICENSE verbatim (missing: '$want')"; break; }
    done < "$up"
    linked_mit=$((linked_mit+1))
done < <(grep '^linked:' "$RES/THIRD-PARTY-NOTICES.md" | grep 'licence: MIT' || true)
[ "$linked_mit" -gt 0 ] || bad "no linked MIT package was checked — the manifest parse is broken, so this would pass while attributing nothing"

if [ "$fail" -ne 0 ]; then
    echo "verify-bundle: FAILED — the bundle does not match its licence documents." >&2
    exit 1
fi
echo "verify-bundle: ok"
