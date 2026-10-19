#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
payload=$(cat)
path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
[ -n "$path" ] && [ -f "$path" ] || exit 0
case "$path" in
  *.ts|*.tsx|*.js|*.mjs|*.json) ;;
  *) exit 0 ;;
esac
cd "$root"
pnpm exec oxfmt --no-error-on-unmatched-pattern -- "$path"
