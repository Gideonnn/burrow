#!/usr/bin/env bash
# Spawn (or remove) a dev-ready git worktree under .claude/worktrees/.
#
#   ./.agents/scripts/worktree.sh <name> [-b <branch>] [--base <ref>]
#   ./.agents/scripts/worktree.sh --rm <name>
#
# Creates the worktree on a new branch (default feat/<name>) from a fresh
# origin/main (the local main when offline), links the gitignored env files
# from the main checkout and installs dependencies. The env files are symlinks,
# not copies, so a variable added later reaches every worktree; the linking
# lives here because the secrets hook blocks commands that name an env file.

set -euo pipefail
ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
cd "$ROOT"

NAME="" BRANCH="" BASE="" REMOVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rm) REMOVE=1 ;;
    -b) BRANCH="$2"; shift ;;
    --base) BASE="$2"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) NAME="$1" ;;
  esac
  shift
done
[ -n "$NAME" ] || { echo "usage: worktree.sh <name> [-b branch] [--base ref] | --rm <name>" >&2; exit 1; }

WT="$ROOT/.claude/worktrees/$NAME"

if [ "$REMOVE" = 1 ]; then
  git worktree remove "$WT"   # refuses when dirty; that is the point
  echo "removed $WT (branch kept)"
  exit 0
fi

[ -e "$WT" ] && { echo "worktree $WT already exists" >&2; exit 1; }
BRANCH="${BRANCH:-feat/$NAME}"

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git worktree add "$WT" "$BRANCH"
else
  if [ -z "$BASE" ]; then
    if git fetch --quiet origin main 2>/dev/null; then BASE="origin/main"; else BASE="main"; fi
  fi
  # --no-track keeps a bare `git push` from aiming the branch at main.
  git worktree add --no-track -b "$BRANCH" "$WT" "$BASE"
fi

linked=0
while IFS= read -r f; do
  case "$f" in *.example|*.enc) continue ;; esac
  rel="${f#"$ROOT"/}"
  mkdir -p "$WT/$(dirname "$rel")"
  target=$(perl -MFile::Spec -e 'print File::Spec->abs2rel($ARGV[0], $ARGV[1])' "$f" "$WT/$(dirname "$rel")")
  ln -sfn "$target" "$WT/$rel"
  linked=$((linked + 1))
done < <(find "$ROOT" -maxdepth 3 -name '.env*' -type f -not -path '*/node_modules/*' -not -path '*/.claude/*')
echo "linked $linked env file(s)"

( cd "$WT" && pnpm install --silent )
echo "ready: $WT (branch $BRANCH, base ${BASE:-existing branch})"
