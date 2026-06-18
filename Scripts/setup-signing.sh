#!/usr/bin/env bash
#
# setup-signing.sh — one-time, USER-RUN setup of a stable local code-signing identity.
#
# WHY: build-app.sh ad-hoc signs by default, which mints a NEW code identity on
# every rebuild. macOS keys the Accessibility (AX) grant to code identity, so the
# auto-paste ⌘V permission is silently forgotten on each rebuild. A stable,
# self-signed identity gives the app a constant code identity → the AX grant
# survives rebuilds.
#
# ⚠️  THIS SCRIPT MODIFIES YOUR LOGIN KEYCHAIN.
#     It creates a self-signed code-signing certificate named "Ditto Local Signing"
#     and imports it (private key + cert) into your login keychain. macOS MAY PROMPT
#     YOU FOR YOUR LOGIN PASSWORD one or more times to authorize this. The identity
#     is local-only, self-signed, and used solely to sign your local Ditto.app build.
#     It is NOT a trusted/Apple-issued certificate and cannot sign for distribution.
#
# Idempotent: if the identity already exists it does nothing and exits 0.
# Safe to re-run.
#
set -euo pipefail

IDENTITY_NAME="Ditto Local Signing"

# --- Already present? Then there is nothing to do. ---------------------------
# `security find-identity -v -p codesigning` lists valid identities usable for
# codesigning; if ours is in there, bail out early (idempotent).
if security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY_NAME"; then
    echo "✓ Code-signing identity already present: \"$IDENTITY_NAME\" — nothing to do."
    exit 0
fi

echo "▸ Creating self-signed code-signing identity \"$IDENTITY_NAME\"…"
echo "  (This writes to your LOGIN KEYCHAIN and may prompt for your password.)"

LOGIN_KEYCHAIN="$(security login-keychain | tr -d ' "')"

# --- Work in a private temp dir; always clean it up. -------------------------
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

KEY="$WORKDIR/key.pem"
CRT="$WORKDIR/cert.pem"
P12="$WORKDIR/identity.p12"
CFG="$WORKDIR/openssl.cnf"
# Throwaway passphrase for the intermediate PKCS#12 container only.
P12_PASS="ditto-local-signing"

# OpenSSL config: a code-signing leaf cert (Extended Key Usage = codeSigning).
cat > "$CFG" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = Ditto Local Signing

[ v3 ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
EOF

# 1) Generate a private key + self-signed code-signing certificate (10 years).
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY" -out "$CRT" \
    -days 3650 -config "$CFG"

# 2) Bundle key+cert into a PKCS#12.
#    Apple's `security import` cannot read OpenSSL 3's default (AES-256) PKCS#12
#    encryption, so we MUST use the legacy SHA1/3DES algorithms. The -legacy flag
#    (OpenSSL 3) plus the explicit -macalg / -certpbe / -keypbe selectors produce
#    a container the system `security` tool can parse.
openssl pkcs12 -export \
    -inkey "$KEY" -in "$CRT" \
    -out "$P12" \
    -name "$IDENTITY_NAME" \
    -legacy \
    -macalg sha1 \
    -certpbe PBE-SHA1-3DES \
    -keypbe PBE-SHA1-3DES \
    -passout "pass:$P12_PASS"

# 3) Import into the login keychain.
#    -A         : allow any application to access the imported key (avoids repeated
#                 keychain-access prompts when codesign runs).
#    -T codesign: explicitly trust /usr/bin/codesign to use the key.
security import "$P12" \
    -k "$LOGIN_KEYCHAIN" \
    -P "$P12_PASS" \
    -A \
    -T /usr/bin/codesign

# --- Verify the identity is now usable for codesigning. ----------------------
if security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY_NAME"; then
    echo "✓ Created \"$IDENTITY_NAME\" in $LOGIN_KEYCHAIN"
    echo "  Now run Scripts/build-app.sh — it will prefer this identity over ad-hoc signing."
else
    echo "✗ Import completed but \"$IDENTITY_NAME\" is not listed as a codesigning identity." >&2
    exit 1
fi
