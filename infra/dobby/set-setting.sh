#!/usr/bin/env bash
# Sets one value in the server settings on Dobby from the Mac and restarts the
# server, e.g.:
#
#   pnpm dobby:set OPENAI_API_KEY
#
# The value is typed hidden and travels over ssh's stdin, so it never shows up
# on a command line, in shell history or in the agent's transcript.
set -euo pipefail

HOST="${DOBBY:-dobby}"
name="${1:-}"
if [[ ! "$name" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
  echo "usage: pnpm dobby:set NAME   (in capitals, e.g. OPENAI_API_KEY)" >&2
  exit 1
fi

read -rsp "$name: " value
echo
if [[ -z "$value" ]]; then
  echo "nothing typed; left alone" >&2
  exit 1
fi
# systemd's EnvironmentFile and bash both read the file; these characters
# need no quoting in either.
if [[ ! "$value" =~ ^[A-Za-z0-9._~:/+=@-]+$ ]]; then
  echo "the value holds spaces, quotes or other characters this script does not quote; edit the file by hand" >&2
  exit 1
fi

remote=$(
  cat <<'EOF'
set -euo pipefail
file="${BURROW_SETTINGS_FILE:-$HOME/.config/burrow/burrow.env}"
IFS= read -r value
umask 077
tmp="$(mktemp "$file.XXXXXX")"
NAME="$1" VALUE="$value" awk '
  BEGIN { line = ENVIRON["NAME"] "=" ENVIRON["VALUE"] }
  index($0, ENVIRON["NAME"] "=") == 1 { if (!done) print line; done = 1; next }
  { print }
  END { if (!done) print line }
' "$file" > "$tmp"
mv "$tmp" "$file"
systemctl --user restart burrow
sleep 2
systemctl --user is-active --quiet burrow && echo "$1 set; the server restarted" || {
  echo "$1 set, but the server did not come back; see journalctl --user -u burrow" >&2
  exit 1
}
EOF
)

printf '%s\n' "$value" | ssh "$HOST" "bash -c $(printf '%q' "$remote") _ $name"
