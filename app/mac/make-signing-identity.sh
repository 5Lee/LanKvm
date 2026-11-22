#!/bin/bash
# Creates the local code signing identity that LanKvm.app is signed with.
#
# Why this exists
# ---------------
# macOS records the Accessibility grant against the code's *designated
# requirement*. An ad-hoc signature is identified by its cdhash, which changes
# on every rebuild, so each rebuild silently invalidated the user's grant while
# System Settings still showed the switch as on. Signing with a named identity
# makes the requirement `identifier + certificate`, which survives a rebuild.
#
# Run this once per machine. build.sh picks the identity up automatically and
# falls back to ad-hoc signing when it is missing.
set -euo pipefail

NAME="${1:-LanKvm Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Identity \"$NAME\" already exists; nothing to do."
  exit 0
fi

echo "==> Generating a self-signed code signing certificate"
cat > "$WORK/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -config "$WORK/cert.conf" 2>/dev/null

# OpenSSL 3 defaults to AES-256-CBC with a SHA-256 MAC, which macOS cannot read.
# -legacy restores the RC2/3DES encoding that the Security framework expects.
openssl pkcs12 -export -out "$WORK/identity.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout pass:lankvm -legacy -descert 2>/dev/null

echo "==> Importing into the login keychain"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P lankvm \
  -T /usr/bin/codesign -A >/dev/null

# Let codesign use the key without prompting for the keychain password.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "==> Trusting the certificate for code signing"
security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$WORK/cert.pem"

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Done. \"$NAME\" is ready; build.sh will use it automatically."
else
  echo "The certificate was imported but is not trusted yet." >&2
  echo "Open Keychain Access, find \"$NAME\", and set it to Always Trust." >&2
  exit 1
fi
