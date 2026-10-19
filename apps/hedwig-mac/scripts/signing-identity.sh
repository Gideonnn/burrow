#!/usr/bin/env bash
# One time, by the operator: makes a self-signed code signing identity
# "Burrow Hedwig" in the login keychain, which bundle.sh then uses.
#
#   ./apps/hedwig-mac/scripts/signing-identity.sh
#
# Why: an ad hoc signature changes with every build, so macOS asks for the
# login password before each new Hedwig may read its API key from the
# keychain. With a fixed certificate the keychain recognises every build, and
# "Sta altijd toe" holds across updates, also on Angela's Mac. The first build
# signed this way asks once more. The first codesign run may ask whether
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
echo "Made \"$NAME\". Build Hedwig again (pnpm hedwig:install); later releases use it too."
