#!/usr/bin/env bash
# Shows which keys an encrypted dotenv holds, never a value: KEY=<redacted:LEN>.
# Warns about values that break as credentials: quoted, padded with spaces,
# empty or ending in `=` (base64 padding has gone missing in round trips).
set -euo pipefail

[ $# -eq 1 ] || {
  echo "usage: $(basename "$0") <file.env.enc>" >&2
  exit 1
}

decrypted=$(sops --input-type dotenv --output-type dotenv -d "$1")
while IFS='=' read -r key value; do
  case "$key" in '' | \#*) continue ;; esac
  warn=""
  case "$value" in
    "") warn=" (empty)" ;;
    \"* | \'*) warn=" (quoted; the quotes become part of the value)" ;;
    " "* | *" ") warn=" (leading or trailing space)" ;;
    *=) warn=" (ends in =; prefer hex)" ;;
  esac
  echo "$key=<redacted:${#value}>$warn"
done <<<"$decrypted"
