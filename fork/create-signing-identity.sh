#!/usr/bin/env bash
#
# Creates a self-signed code signing identity in the login keychain for
# install-ghostty-pro.sh to sign with.
#
# macOS remembers privacy answers (Photos, Documents, ...) per app signature. An
# ad hoc signature changes with every build, so each reinstall asked again. A
# stable certificate keeps those answers across rebuilds.
#
# Run it once per Mac: fork/create-signing-identity.sh
#
# Override with IDENTITY (and pass the same SIGN_IDENTITY to the install script).

set -euo pipefail

IDENTITY="${IDENTITY:-Ghostty Pro Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# LibreSSL, not Homebrew's OpenSSL 3: its .p12 encryption is what `security
# import` can read.
OPENSSL=/usr/bin/openssl

if security find-identity -p codesigning "$KEYCHAIN" | grep -qF "\"$IDENTITY\""; then
    echo "==> \"$IDENTITY\" already exists. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Creating certificate \"$IDENTITY\" (valid for 10 years)"
cat >"$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -name "$IDENTITY" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout pass:import -out "$WORK/identity.p12"

echo "==> Importing into the login keychain"
# -T lets codesign use the key without asking each time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P import -T /usr/bin/codesign >/dev/null

echo "==> Done. install-ghostty-pro.sh now signs with \"$IDENTITY\"."
