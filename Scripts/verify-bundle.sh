#!/usr/bin/env bash
# Prove an assembled .app matches what the licence documents claim about it.
#
# This exists because the unit suite cannot protect the artifact: `release.yml` runs no
# tests at all, so on the CI path nothing between "compile" and "notarise and publish"
# ever looks at what actually landed in Resources. The defect this was written for is
# live and silent: `restore-models.sh` has no `openvision-*` case and the `models-v1`
# release has no openvision asset, so a CI-cut DMG ships ZERO models while
# THIRD-PARTY-NOTICES.md at its root says OpenVision is BUNDLED. Image search would be
# permanently dead and the attribution statement would be false.
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

# 2. Jinja is statically linked into the binary (verified: `nm` finds its symbols), and
#    MIT requires its copyright notice travel with every copy. The notice lives in
#    THIRD-PARTY-NOTICES.md; assert it is really there rather than assuming.
if ! grep -q "Copyright (c) 2024 John Mai" "$RES/THIRD-PARTY-NOTICES.md" 2>/dev/null; then
    bad "THIRD-PARTY-NOTICES.md carries no Jinja copyright notice, but Jinja is linked in"
fi

# 3. Every model the build intended to bundle, checked two ways.
for m in ${BUNDLE_MODELS:-}; do
    if [ -d "$RES/$m.mlmodelc" ]; then
        note "✓" "$m bundled"
        grep -qi "$(echo "$m" | cut -d- -f1)" "$RES/THIRD-PARTY-NOTICES.md" \
            || bad "$m ships with no entry in THIRD-PARTY-NOTICES.md"
    elif [ -d "$ROOT/tools/models/$m.mlpackage" ]; then
        # Source present, output absent: the compile failed and was swallowed.
        bad "$m has a .mlpackage but no .mlmodelc in the app — coremlcompiler failed silently"
    elif [ "${STRICT_BUNDLE:-0}" = "1" ]; then
        bad "$m is missing (STRICT_BUNDLE=1). A release must not ship an empty bundle while
     THIRD-PARTY-NOTICES.md says this model is BUNDLED. Run Scripts/restore-models.sh, or
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
