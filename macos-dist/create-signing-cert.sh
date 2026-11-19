#!/bin/bash
# Create the stable self-signed code-signing identity that Skylight.app is signed with.
# TCC (Screen Recording / Accessibility) keys on this identity, so signing every rebuild
# with the SAME cert keeps the grants across rebuilds. Run once per machine.
# (On a new machine you still grant Screen Recording + Accessibility once — TCC is per-Mac.)
set -euo pipefail
CERT_NAME="${CERT_NAME:-Lumen Local Signing}"
command -v brew >/dev/null 2>&1 || { echo "ERROR: Homebrew not found — install it from https://brew.sh, then re-run." >&2; exit 1; }
brew --prefix openssl@3 >/dev/null 2>&1 || { echo "ERROR: openssl@3 not installed — run 'brew install openssl@3', then re-run." >&2; exit 1; }
OSSL="$(brew --prefix openssl@3)/bin/openssl"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
P12_PASS="$("$OSSL" rand -hex 16)"

if security find-certificate -c "$CERT_NAME" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
  echo "'$CERT_NAME' already in login keychain — nothing to do."; exit 0
fi

echo "==> generating self-signed codesigning cert (10y)…"
"$OSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$CERT_NAME/O=Skylight" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

echo "==> packaging p12 (legacy crypto for macOS security import)…"
"$OSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout "pass:$P12_PASS" -name "$CERT_NAME" \
  -legacy -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

echo "==> importing into login keychain (codesign access)…"
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P "$P12_PASS" -T /usr/bin/codesign
echo "==> done. Your keychain may ask you to authorize codesign."
