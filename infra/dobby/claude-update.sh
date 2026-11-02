#!/usr/bin/env bash
# Nightly Claude Code update. The bots name `haiku` or `opus`, which the CLI
# resolves by its own version, so a new model only arrives with a new CLI.
# After updating it asks one structured answer the way the server does; when
# that fails it points ~/.local/bin/claude back at the previous version, so a
# changed flag never stops every agent task. Runs from the burrow-claude-update
# timer that install.sh sets up.
set -euo pipefail
link="$HOME/.local/bin/claude"
before="$(readlink "$link")"

"$link" update </dev/null >/dev/null 2>&1 || {
  echo "$(date -Is) claude update failed, staying on $(basename "$before")"
  exit 1
}
after="$(readlink "$link")"
[ "$after" = "$before" ] && exit 0

answer="$(cd /tmp && echo "Name a colour." | "$link" -p --model haiku --output-format json \
  --tools "" --strict-mcp-config --no-session-persistence --system-prompt "Answer briefly." \
  --json-schema '{"type":"object","properties":{"colour":{"type":"string"}},"required":["colour"],"additionalProperties":false}' \
  2>/dev/null | tail -n 1 || true)"
if node -e 'const d = JSON.parse(process.argv[1]); if (!d.structured_output?.colour) process.exit(1)' "$answer" 2>/dev/null; then
  echo "$(date -Is) claude $(basename "$before") -> $(basename "$after")"
  exit 0
fi

if [ -e "$before" ]; then
  ln -sfn "$before" "$link"
  echo "$(date -Is) claude $(basename "$after") failed the check, back on $(basename "$before")"
else
  echo "$(date -Is) claude $(basename "$after") failed the check and $(basename "$before") is gone"
fi
exit 1
