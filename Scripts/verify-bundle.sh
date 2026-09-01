#!/usr/bin/env bash
# Prove an assembled .app matches what the licence documents claim about it.
#
# This exists because the unit suite cannot protect the artifact: `release.yml` runs no
# tests at all, so on the CI path nothing between "compile" and "notarise and publish"
# ever looks at what actually landed in Resources. The defect this was written for WAS
# live and silent: `restore-models.sh` had no `openvision-*` case and the `models-v1`
# release had no openvision asset, so a CI-cut DMG shipped ZERO models while
# THIRD-PARTY-NOTICES.md at its root said OpenVision is BUNDLED. Fixed: restore-models.sh
# downloads the pinned openvision-tiny-p8.zip; STRICT_BUNDLE=1 below keeps it fixed.
#
# Usage: verify-bundle.sh <app> <repo-root> [extra-dir-that-must-carry-licences]
# Env:   BUNDLE_MODELS  the models this build intended to bundle
#        STRICT_BUNDLE  1 => a missing bundled model is fatal (release.sh sets this)
#
# STRICT is opt-in for a reason. `build-app.sh` documents that an absent model is a
# legitimate developer state — the app falls back to the built-in HashingEmbedder — so a
# flat "must be present" check would break `make app` on a fresh clone. What is ALWAYS
# fatal is narrower and catches the real hole: a model whose .mlpackage exists in
# tools/models but whose .mlmodelc did not reach the app. That means the compile step
# failed and was swallowed (build-app.sh pipes coremlcompiler stderr to /dev/null), which
# no fallback story covers.
set -euo pipefail

APP="${1:?usage: verify-bundle.sh <app> <repo-root> [stage-dir]}"
ROOT="${2:?}"
EXTRA="${3:-}"
RES="$APP/Contents/Resources"
fail=0
note() { printf '  %s %s\n' "$1" "$2"; }
bad()  { note "✗" "$1"; fail=1; }

echo "verify-bundle: $APP"
[ -d "$RES" ] || { bad "no Contents/Resources — not an app bundle"; exit 1; }

# 1. Licence texts must physically reach the recipient, in every directory that is
#    itself a distribution channel (the .app, and the DMG staging root).
for dir in "$RES" ${EXTRA:+"$EXTRA"}; do
    for f in LICENSE LICENSE-Apache-2.0.txt THIRD-PARTY-NOTICES.md; do
        if [ ! -f "$dir/$f" ]; then
            bad "$dir/$f is missing — a recipient gets the software without its licence"
        elif ! cmp -s "$dir/$f" "$ROOT/$f"; then
            bad "$dir/$f differs from the repository copy"
        fi
    done
done

# 2. LICENSE must be canonical MIT, not merely identical to the repo copy: a repo LICENSE
#    with a prepended or appended clause would otherwise ship in every DMG (this script is
#    the only guard on the CI path). The body hash is taken with the holder line (line 3)
#    masked, so a year bump passes and any other edit fails. The same constant is pinned
#    in DistributionLicenceTests.testTheLicenceIsUnmodifiedMIT.
MIT_BODY_SHA256="ac483bb6267e16aac1620af5d09a1ccd94c3bbab762ac1b3ee391fe18021deae"
for dir in "$RES" ${EXTRA:+"$EXTRA"}; do
    [ -f "$dir/LICENSE" ] || continue
    got="$(sed '3s/.*/@HOLDER@/' "$dir/LICENSE" | shasum -a 256 | cut -d' ' -f1)"
    [ "$got" = "$MIT_BODY_SHA256" ] \
        || bad "$dir/LICENSE is not canonical MIT (masked-holder sha256 $got) — a prepended or appended clause ships to every recipient"
    sed -n 3p "$dir/LICENSE" | grep -Eq '^Copyright \(c\) [0-9]{4}(-[0-9]{4})? Antreas Antoniou$' \
        || bad "$dir/LICENSE line 3 is not the plain copyright line"
done

# 3. Every MIT package linked into the binary (Jinja: `nm` finds its symbols) must have its
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
    up="$ROOT/.build/checkouts/$name/LICENSE"
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

# 4. Every model the build intended to bundle, checked two ways. Under STRICT an empty
#    list is itself a failure: a strict check that checks nothing passes anything.
if [ "${STRICT_BUNDLE:-0}" = "1" ] && [ -z "${BUNDLE_MODELS:-}" ]; then
    bad "STRICT_BUNDLE=1 but BUNDLE_MODELS is empty — a release must declare what it bundles"
fi
for m in ${BUNDLE_MODELS:-}; do
    if [ -d "$RES/$m.mlmodelc" ]; then
        note "✓" "$m bundled"
        # Attribute by upstream family (first two dash-separated components) against a
        # visible `### ` heading only: `all` matched 13 places and `embeddinggemma` matched
        # the paragraph saying it was REMOVED.
        family="$(printf '%s' "$m" | cut -d- -f1-2)"
        section="$(section_for "$(printf '%s' "$family" | tr 'A-Z' 'a-z')")"
        if [ -z "$section" ]; then
            bad "$m ships with no visible '### …$family…' entry in THIRD-PARTY-NOTICES.md"
        else
            grep -q '^- \*\*How it reaches you:\*\* \*\*BUNDLED\.\*\*' <<< "$section" \
                || bad "$m is inside the .app but its notices entry does not say **BUNDLED.**"
        fi
    elif [ -d "$ROOT/tools/models/$m.mlpackage" ]; then
        # Source present, output absent: the compile failed and was swallowed.
        bad "$m has a .mlpackage but no .mlmodelc in the app — coremlcompiler failed silently"
    elif [ "${STRICT_BUNDLE:-0}" = "1" ]; then
        bad "$m is missing (STRICT_BUNDLE=1). A release must not ship an empty bundle while
     THIRD-PARTY-NOTICES.md says this model is BUNDLED. Run tools/restore-models.sh, or
     if it has no case for this model, that is the bug."
    else
        note "·" "$m absent (dev build; app falls back to HashingEmbedder)"
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "verify-bundle: FAILED — the bundle does not match its licence documents." >&2
    exit 1
fi
echo "verify-bundle: ok"
