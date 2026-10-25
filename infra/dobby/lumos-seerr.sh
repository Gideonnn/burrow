#!/usr/bin/env bash
# Connects Lumos to the Seerr on Dobby, without printing its key:
#
#   ./infra/dobby/lumos-seerr.sh
#
# The media stack keeps Seerr's API key in a root-only folder, so this asks
# for the sudo password once. It copies the key into the server settings,
# sets the address Seerr listens on, checks the key with a read-only call and
# restarts the server.
set -euo pipefail

HOST="${DOBBY:-dobby}"
ssh -t "$HOST" 'set -euo pipefail
  addr=$(ss -ltnH "sport = :5055" | awk "{print \$4}" | head -1)
  [ -n "$addr" ] || { echo "Seerr does not listen on port 5055" >&2; exit 1; }
  key=$(sudo cat /opt/media-stack/secrets/seerr_api_key)
  [ -n "$key" ] || { echo "the Seerr key is empty" >&2; exit 1; }
  code=$(printf "header = \"X-Api-Key: %s\"\n" "$key" | curl -s -o /dev/null -w "%{http_code}" -K - "http://$addr/api/v1/auth/me")
  [ "$code" = 200 ] || { echo "Seerr refused the key (HTTP $code)" >&2; exit 1; }
  printf "%s" "$key" | LUMOS_URL="http://$addr" node -e "
    const fs = require(\"node:fs\");
    const file = process.env.HOME + \"/.config/burrow/burrow.env\";
    const key = fs.readFileSync(0, \"utf8\").trim();
    const lines = fs.readFileSync(file, \"utf8\").split(\"\n\")
      .filter((l) => !l.startsWith(\"LUMOS_SEERR_URL=\") && !l.startsWith(\"LUMOS_SEERR_API_KEY=\"));
    while (lines.length && lines.at(-1) === \"\") lines.pop();
    lines.push(\"LUMOS_SEERR_URL=\" + process.env.LUMOS_URL, \"LUMOS_SEERR_API_KEY=\" + key, \"\");
    fs.writeFileSync(file, lines.join(\"\n\"), { mode: 0o600 });
    console.log(\"Lumos: Seerr at \" + process.env.LUMOS_URL + \", key set (\" + key.length + \" characters)\");
  "
  unset key
  ~/burrow/infra/dobby/install.sh | tail -3'
