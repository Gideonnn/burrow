#!/usr/bin/env bash
# Puts an OAuth client's id and secret in the server settings on Dobby, from the
# JSON file the provider's console downloads, without printing either:
#
#   ./infra/dobby/oauth-client.sh google ~/Downloads/client_secret_….json
#
# The file is copied over SSH, read on Dobby with node, and deleted on both
# sides; then the install runs to restart the server.
set -euo pipefail

PROVIDER="${1:-}"
FILE="${2:-}"
HOST="${DOBBY:-dobby}"
case "$PROVIDER" in
  google) PREFIX=GOOGLE ;;
  *) echo "usage: $(basename "$0") google <client json>" >&2; exit 1 ;;
esac
[ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 1; }

REMOTE=".config/burrow/oauth-client.json"
scp -q "$FILE" "$HOST:$REMOTE"
ssh "$HOST" "PREFIX=$PREFIX bash -s" <<'SH'
set -euo pipefail
cd ~/.config/burrow
trap 'rm -f oauth-client.json' EXIT
chmod 600 oauth-client.json
node -e '
  const fs = require("node:fs");
  const json = JSON.parse(fs.readFileSync("oauth-client.json", "utf8"));
  const client = json.web ?? json.installed;
  if (!client?.client_id || !client?.client_secret) { console.error("no client_id/client_secret in the file"); process.exit(1); }
  const p = process.env.PREFIX;
  const lines = fs.readFileSync("burrow.env", "utf8").split("\n")
    .filter((l) => !l.startsWith(p + "_CLIENT_ID=") && !l.startsWith(p + "_CLIENT_SECRET="));
  while (lines.length && lines.at(-1) === "") lines.pop();
  lines.push(p + "_CLIENT_ID=" + client.client_id, p + "_CLIENT_SECRET=" + client.client_secret, "");
  fs.writeFileSync("burrow.env", lines.join("\n"), { mode: 0o600 });
  console.log(p + " client set (id ends in " + client.client_id.slice(-24) + ")");
'
SH
rm -f "$FILE"
echo "→ deleted $FILE; restarting the server"
ssh "$HOST" '~/burrow/infra/dobby/install.sh' | tail -3
