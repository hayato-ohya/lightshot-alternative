#!/bin/zsh
# Creates a self-signed code-signing certificate "Lightshot Alternative Dev" in the login keychain.
# Signing with a fixed certificate keeps the Screen Recording permission across rebuilds;
# ad-hoc signatures change with every build and macOS silently drops the grant.
set -euo pipefail
NAME="Lightshot Alternative Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Certificate '$NAME' already exists."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null
openssl pkcs12 -export -legacy -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:tmp
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P tmp -T /usr/bin/codesign -T /usr/bin/security
# Trust it for code signing (macOS shows a password dialog here).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
echo
security find-identity -v -p codesigning | grep "$NAME" && echo "Done. Now run: ./build.sh install"
