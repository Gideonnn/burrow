#!/usr/bin/env bash
# Runs a command with the values of infra/secrets/<file>.env.enc in its
# environment. The plaintext lives only in this process and the command.
#
#   pnpm with-secrets tools ./some-script.sh
#   pnpm with-secrets tools sh -c 'curl -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" ...'
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $(basename "$0") <file> <command> [args...]" >&2
  exit 1
fi
name="$1"
shift
case "$name" in
  "" | *[!a-z0-9-]*)
    echo "invalid secrets file name: $name" >&2
    exit 1
    ;;
esac

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
file="$repo/infra/secrets/$name.env.enc"
[ -f "$file" ] || {
  echo "missing $file; create it with: pnpm sops:edit $file" >&2
  exit 1
}

# `sops exec-env` parses files without a known extension as JSON, so decrypt
# and read the dotenv lines here. Values stay opaque: no shell expansion.
decrypted=$(sops --input-type dotenv --output-type dotenv -d "$file")
while IFS='=' read -r key value; do
  case "$key" in '' | \#*) continue ;; esac
  export "$key=$value"
done <<<"$decrypted"
unset decrypted key value

exec "$@"
