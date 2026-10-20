#!/usr/bin/env bash
# Create a self-signed code-signing certificate in the login keychain.
#
# Why: macOS ties Screen Recording permission to an app's code signature.
# Ad-hoc signed builds are identified by a hash of the binary itself, so every
# recompile looks like a brand new app and the permission you granted stops
# applying. A stable certificate fixes that for good.
set -euo pipefail

NAME="${1:-ScreenUpscaler Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Certificate '$NAME' already exists - nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "==> generating key and certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" 2>/dev/null
openssl pkcs12 -export -out "$TMP/cert.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass: 2>/dev/null

echo "==> importing into the login keychain"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "==> trusting it for code signing (requires your password)"
# Needs admin: an untrusted certificate is not usable as a signing identity.
sudo security add-trusted-cert -d -r trustRoot \
    -p codeSign -k /Library/Keychains/System.keychain "$TMP/cert.pem"

# Stop the keychain prompting on every codesign invocation.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "done - '$NAME' is now a usable signing identity."
    echo "Run 'make reset-permission && make run', then grant Screen Recording once."
else
    echo "certificate created but not visible to codesign."
    echo "Open Keychain Access, find '$NAME', set Trust > Code Signing to 'Always Trust'."
    exit 1
fi
