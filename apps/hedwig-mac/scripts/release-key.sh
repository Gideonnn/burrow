#!/usr/bin/env bash
# One time, by the operator: makes the Hedwig release key.
#
#   ./apps/hedwig-mac/scripts/release-key.sh
#
# The private half goes into infra/secrets/tools.env.enc as HEDWIG_RELEASE_KEY
# without being shown; the public half goes into ReleaseKey.swift, which you
# commit. Hedwig installs only builds signed with this key.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(cd ../.. && pwd)"
SECRETS="infra/secrets/tools.env.enc"

if (cd "$REPO" && ./infra/scripts/sops-verify.sh "$SECRETS") | grep -q '^HEDWIG_RELEASE_KEY='; then
  echo "HEDWIG_RELEASE_KEY already exists; remove it with pnpm sops:edit first to make a new one" >&2
  exit 1
fi

KEYS="$(node -e '
  const c = require("node:crypto");
  const { publicKey, privateKey } = c.generateKeyPairSync("ed25519");
  console.log(privateKey.export({ type: "pkcs8", format: "der" }).toString("base64"));
  console.log(publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("base64"));
')"
export HEDWIG_RELEASE_KEY_LINE="HEDWIG_RELEASE_KEY=$(sed -n 1p <<<"$KEYS")"
PUBLIC="$(sed -n 2p <<<"$KEYS")"

# sops opens the decrypted file in $EDITOR; this editor only appends the line.
EDITOR_SCRIPT="$(mktemp)"
trap 'rm -f "$EDITOR_SCRIPT"' EXIT
cat >"$EDITOR_SCRIPT" <<'SH'
#!/bin/sh
[ -n "$(tail -c1 "$1")" ] && echo >>"$1"
printf '%s\n' "$HEDWIG_RELEASE_KEY_LINE" >>"$1"
SH
chmod +x "$EDITOR_SCRIPT"
(cd "$REPO" && EDITOR="$EDITOR_SCRIPT" sops --input-type dotenv --output-type dotenv "$SECRETS")
unset HEDWIG_RELEASE_KEY_LINE

sed -i '' "s|public static let publicKey = \".*\"|public static let publicKey = \"$PUBLIC\"|" Sources/HedwigCore/Update/ReleaseKey.swift
echo "Release key made. Tell the agent; it commits ReleaseKey.swift and $SECRETS."
