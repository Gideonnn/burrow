#!/usr/bin/env bash
# Wait for a pull request's checks, then merge it with a merge commit and
# update the local main:  ./.agents/scripts/merge-pr.sh <number>
set -euo pipefail
pr="${1:?usage: merge-pr.sh <number>}"

sleep 10
for _ in $(seq 1 60); do
  checks=$(gh pr checks "$pr" --json name,bucket 2>/dev/null || echo '[]')
  if jq -e 'length > 0 and all(.bucket != "pending")' <<<"$checks" >/dev/null; then
    jq -r '.[] | "\(.name): \(.bucket)"' <<<"$checks"
    if jq -e 'any(.bucket == "fail" or .bucket == "cancel")' <<<"$checks" >/dev/null; then
      echo "checks failed; not merging" >&2
      exit 1
    fi
    gh pr merge "$pr" --merge --delete-branch >/dev/null
    git checkout -q main
    git pull -q --ff-only
    git log --oneline -1
    exit 0
  fi
  sleep 10
done
echo "checks still pending after 10 minutes" >&2
exit 1
