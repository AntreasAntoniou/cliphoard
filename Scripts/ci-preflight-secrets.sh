#!/usr/bin/env bash
# ci-preflight-secrets.sh — fail in seconds, BY NAME, when the release secrets are missing or
# malformed, instead of twenty minutes later with security(1)'s "Unknown format in import".
# Run by release.yml before anything else on a tag build; runnable locally with the seven
# variables in the environment. Prints no secret values.
set -euo pipefail

missing=""
for v in MACOS_CERT_P12 MACOS_CERT_PASSWORD KEYCHAIN_PASSWORD MACOS_DEVID APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    [ -n "${!v:-}" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
    echo "::error::release cannot sign or notarise — missing repository secret(s):$missing. Add each with: gh secret set <NAME> -R AntreasAntoniou/cliphoard (RELEASING.md, One-time setup, step 3), then re-run."
    exit 1
fi

# MACOS_DEVID must be the exact codesign identity string, and its Team ID must be the one
# notarytool is given — release.sh derives the keychain-access-group from it.
printf '%s' "$MACOS_DEVID" | grep -Eq '^Developer ID Application: .+ \([A-Z0-9]{10}\)$' \
    || { echo "::error::MACOS_DEVID is not of the form 'Developer ID Application: Name (TEAMID)' — copy it verbatim from: security find-identity -v -p codesigning"; exit 1; }
team="$(printf '%s' "$MACOS_DEVID" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
[ "$team" = "$APPLE_TEAM_ID" ] \
    || { echo "::error::the Team ID inside MACOS_DEVID does not equal APPLE_TEAM_ID — codesign and notarytool would use different teams"; exit 1; }

# The .p12 must decode AND open with its password. macOS base64 --decode exits 0 on garbage,
# so decoding is not a check; opening the PKCS#12 bundle is. /usr/bin/openssl (LibreSSL)
# reads Keychain Access's legacy PKCS#12 format; Homebrew's OpenSSL 3 may not.
tmp="${RUNNER_TEMP:-build}"; mkdir -p "$tmp"
printf '%s' "$MACOS_CERT_P12" | base64 --decode > "$tmp/preflight.p12" 2>/dev/null || true
if ! /usr/bin/openssl pkcs12 -in "$tmp/preflight.p12" -nokeys -noout -passin env:MACOS_CERT_PASSWORD >/dev/null 2>&1; then
    rm -f "$tmp/preflight.p12"
    echo "::error::MACOS_CERT_P12 + MACOS_CERT_PASSWORD do not open as a PKCS#12 bundle — export the Developer ID Application certificate WITH its private key from Keychain Access as .p12, then: base64 -i Certificates.p12 | tr -d '\n' | gh secret set MACOS_CERT_P12 -R AntreasAntoniou/cliphoard"
    exit 1
fi
rm -f "$tmp/preflight.p12"
echo "✓ all 7 release secrets present; MACOS_DEVID well-formed and matches APPLE_TEAM_ID; the .p12 opens with its password"
