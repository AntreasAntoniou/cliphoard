#!/usr/bin/env bash
# Prove an assembled .app matches what the licence documents claim about it.
#
# This exists because the unit suite cannot protect the artifact: `release.yml` runs no
# tests at all, so on the CI path this script is the only thing between "compile" and
# "notarise and publish" that looks at what actually landed in Resources. The defect this
# was written for WAS live and silent: `restore-models.sh` had no `openvision-*` case and
# the `models-v1` release had no openvision asset, so a CI-cut DMG shipped ZERO models while
# THIRD-PARTY-NOTICES.md at its root said OpenVision is BUNDLED. Fixed: restore-models.sh
# downloads the pinned openvision-tiny-p8.zip; STRICT_BUNDLE=1 below keeps it fixed.
#
# Checks: 1 licence files present + identical to the repo · 2 LICENSE is canonical MIT with a
#         single-year holder line (1073 bytes) · 3 LICENSE-Apache-2.0.txt is the complete
#         canonical text · 4 linked MIT notices reproduced visibly · 5 every declared model is
#         bundled + attributed · 6 nothing undeclared or hollow in Resources · 7 every bundled
#         text tower carries its tokenizer folder (tokenizer.json + tokenizer_config.json +
#         config.json, each valid JSON).
#
# Usage: verify-bundle.sh <app> <repo-root> [extra-dir-that-must-carry-licences]
# Env:   BUNDLE_MODELS  the models this build intended to bundle
#        STRICT_BUNDLE  1 => a missing bundled model is fatal (release.sh sets this)
#
# Runs under macOS /bin/bash 3.2 (`env bash` resolves to it). In a message, brace a variable
# that is followed by a non-ASCII character: bash 3.2 lexes the name and the following
# multibyte character as ONE identifier and dies "unbound variable" under set -u, so the
# diagnostic never printed and the script failed closed only by accident. Audit:
#   perl -ne 'print "$ARGV: $_" if /\$[A-Za-z_]\w*[\x80-\xFF]/' Scripts/*.sh tools/*.sh
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
#    .testTheApacheTextExistsAndBothBuildPathsShipIt (which release.yml never runs), plus the
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

# 5. Every model the build intended to bundle, checked two ways. Under STRICT an empty
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
            bad "$m ships with no visible '### …${family}…' entry in THIRD-PARTY-NOTICES.md"
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

# 6. The converse of 5: nothing UNDECLARED, nothing HOLLOW. Step 5 iterates BUNDLE_MODELS, so
#    a .mlmodelc inside the .app but not on the list would ship unattributed, and `-d` alone
#    accepts the empty directory a failed coremlcompiler leaves behind (build-app.sh pipes its
#    stderr to /dev/null). A real compile always emits coremldata.bin plus weights/weight.bin
#    (or an inline model.mil for a weightless model).
for d in "$RES"/*.mlmodelc; do
    [ -e "$d" ] || continue
    n="$(basename "$d" .mlmodelc)"
    case " ${BUNDLE_MODELS:-} " in
        *" $n "*) ;;
        *) bad "${n}.mlmodelc is inside the .app but not in BUNDLE_MODELS — an undeclared model ships with no attribution" ;;
    esac
    if [ -s "$d/coremldata.bin" ] && { [ -s "$d/weights/weight.bin" ] || [ -s "$d/model.mil" ]; }; then
        note "✓" "${n}.mlmodelc is a real compiled model"
    else
        bad "${n}.mlmodelc is hollow (no coremldata.bin, or neither weights/weight.bin nor model.mil) — coremlcompiler failed and left an empty directory"
    fi
done
for d in "$RES"/*-tokenizer; do
    [ -e "$d" ] || continue
    n="$(basename "$d")"; n="${n%-tokenizer}"
    case " ${BUNDLE_MODELS:-} " in
        *" $n "*) ;;
        *) bad "$(basename "$d")/ is inside the .app but no bundled model is named ${n}" ;;
    esac
done

# 7. Every bundled TEXT tower needs its tokenizer folder. Which towers are text towers is
#    decided the way build-app.sh decides it (Scripts/build-app.sh:79-86): the source folder
#    tools/models/<name>/tokenizer.json exists. The same fact is read off the artifact too —
#    coremlcompiler's metadata.json declares the `input_ids` input the converter names
#    (tools/convert_openvision.py:171) — so a run without tools/models is not vacuous.
#    swift-transformers' AutoTokenizer.from(modelFolder:) (Hub.swift loadConfig) throws unless
#    tokenizer.json AND config.json exist and parse: the 30-byte config.json is exactly the
#    file whose absence once made image search silently dark. tokenizer_config.json is needed
#    too: without it Hub.swift's tokenizerConfig getter falls back to a bundled config for the
#    model_type, and only gpt2/t5 fallbacks ship — for "bert" that is `missingConfig`, thrown.
#    A verifier proved the first version of this check passed with that file deleted.
#    Validated with python3's json module, NOT plutil: plutil converts to a plist and rejects
#    any JSON containing null, which the real tokenizer_config.json does.
for m in ${BUNDLE_MODELS:-}; do
    [ -d "$RES/$m.mlmodelc" ] || continue
    needs=0
    if [ -d "$ROOT/tools/models/$m.mlpackage" ]; then
        [ -f "$ROOT/tools/models/$m/tokenizer.json" ] && needs=1
    elif [ "${STRICT_BUNDLE:-0}" = "1" ]; then
        bad "${m}: tools/models/${m}.mlpackage is absent, so whether it needs a tokenizer cannot be derived from the build rule — under STRICT that is a failure, not a skip"
    fi
    grep -q '"input_ids"' "$RES/$m.mlmodelc/metadata.json" 2>/dev/null && needs=1
    [ "$needs" = 1 ] || continue
    tok="$RES/$m-tokenizer"
    ok=1
    for f in tokenizer.json tokenizer_config.json config.json; do
        if [ ! -s "$tok/$f" ]; then
            bad "${m} is a text tower but Resources/${m}-tokenizer/${f} is missing or empty — AutoTokenizer.from(modelFolder:) throws and image search is silently dark"; ok=0
        elif ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tok/$f" 2>/dev/null; then
            bad "Resources/${m}-tokenizer/${f} is not valid JSON — AutoTokenizer throws exactly as if it were absent"; ok=0
        fi
    done
    [ "$ok" = 1 ] && note "✓" "${m}-tokenizer carries tokenizer.json + tokenizer_config.json + config.json, all valid JSON"
done

if [ "$fail" -ne 0 ]; then
    echo "verify-bundle: FAILED — the bundle does not match its licence documents." >&2
    exit 1
fi
echo "verify-bundle: ok"
