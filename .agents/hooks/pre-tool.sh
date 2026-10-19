#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
deny() { echo "Blocked: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || deny "jq is required for the repository hooks."
payload=$(cat)
jq -e 'type == "object" and (.tool_name | type == "string") and (.tool_input | type == "object")' \
  <<<"$payload" >/dev/null 2>&1 || deny "Invalid hook input."
tool=$(jq -r '.tool_name' <<<"$payload")

bash "$root/.agents/hooks/block-secrets.sh" <<<"$payload" || deny "block-secrets refused the call."

if [ "$tool" = Bash ]; then
  cmd=$(jq -r '.tool_input.command // empty' <<<"$payload")
  if grep -qE '(^|[^a-zA-Z0-9_-])(npm|npx)([^a-zA-Z0-9_-]|$)' <<<"$cmd"; then
    deny "Use pnpm instead of npm/npx."
  fi
  # Agents use secrets through `pnpm with-secrets`; decrypting or editing is
  # the operator's.
  if grep -qE '(^|[;&|(]\s*)sops(\s|$)|sops:edit' <<<"$cmd"; then
    deny "Running sops is the operator's. Use pnpm with-secrets or pnpm sops:verify."
  fi
fi
