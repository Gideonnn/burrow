#!/usr/bin/env bash
# One time, by the operator: makes a self-signed code signing identity
# "Burrow Hedwig" in the login keychain, which bundle.sh then uses.
#
#   ./packages/burrow-kit/scripts/signing-identity.sh
#
# Only a fallback for sign-app.sh: macOS keeps permissions such as the
# microphone across builds with a fixed certificate, but the keychain still
# asks after every update, because without an Apple team ID it trusts one build
# (cdhash) at a time. An Apple Development certificate (free Apple ID in Xcode)
# fixes that; sign-app.sh prefers it. The first codesign run may ask whether
# codesign may use the key: choose "Sta altijd toe".
set -euo pipefail

NAME="Burrow Hedwig"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists in the keychain"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
umask 077
cat >"$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$WORK/cert.cnf" \
  -keyout "$WORK/private" -out "$WORK/certificate" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/private" -in "$WORK/certificate" -name "$NAME" \
  -out "$WORK/identity" -passout "pass:$PASS" 2>/dev/null
security import "$WORK/identity" -f pkcs12 -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Made \"$NAME\". Build the apps again (pnpm hedwig:install, pnpm pensieve:install); later releases use it too."
