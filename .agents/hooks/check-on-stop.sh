#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

# Only check when something changed; a question-and-answer turn needs no checks.
[ -n "$(git status --porcelain -- ':!docs' 2>/dev/null)" ] || { printf '{}\n'; exit 0; }

status=0
for task in format:check lint typecheck; do
  pnpm "$task" 2>&1 | tail -20 >&2 || status=2
done
if [ "$status" != 0 ]; then
  echo "Repository checks failed; inspect the diagnostics above before completing the task." >&2
  exit "$status"
fi
# Codex parses successful Stop stdout as JSON; diagnostics belong on stderr.
printf '{}\n'
