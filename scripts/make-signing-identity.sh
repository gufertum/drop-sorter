#!/usr/bin/env bash
# Creates a self-signed code-signing identity in your login keychain, once. build.sh signs Drop Sorter
# with it, so macOS privacy grants (e.g. access to a vault in ~/Documents) survive rebuilds.
# Usage: scripts/make-signing-identity.sh [name]          (default name: "Drop Sorter Local")
#        KEYCHAIN=<path> scripts/make-signing-identity.sh  (another keychain, for testing)
# The certificate is not trusted system-wide and is only good for signing your own builds.
set -euo pipefail
NAME="${1:-Drop Sorter Local}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Identity \"$NAME\" already exists in $KEYCHAIN."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
# /usr/bin/openssl (LibreSSL) writes a PKCS#12 file the macOS keychain can import.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/openssl.cnf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
pass="$(/usr/bin/openssl rand -hex 16)"   # only protects the temporary .p12 file
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
  -out "$tmp/identity.p12" -passout "pass:$pass"
# -T: codesign may use the key without asking each time.
security import "$tmp/identity.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\" in $KEYCHAIN. Build with: DROPSORTER_SIGN_ID=\"$NAME\" ./build.sh"
