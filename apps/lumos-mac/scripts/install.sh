#!/usr/bin/env bash
# Builds Lumos and installs it in /Applications, so Spotlight, Launchpad and
# Raycast find it:
#
#   pnpm lumos:install
#
# Quits a running Lumos first and starts the
# new one afterwards. Also installs burrowctl in ~/.local/bin, the CLI and MCP
# server agents use to operate the Burrow apps.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="/Applications/Lumos.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

./scripts/bundle.sh >/dev/null
echo "→ built build/Lumos.app"

../../packages/burrow-kit/scripts/install-burrowctl.sh

if pgrep -xq Lumos; then
  osascript -e 'tell application "Lumos" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -xq Lumos || break; sleep 0.2; done
  pgrep -xq Lumos && { echo "✗ Lumos is still running; stop it first" >&2; exit 1; }
fi

/bin/rm -rf "$TARGET"
/bin/mv build/Lumos.app "$TARGET"
"$LSREGISTER" -f "$TARGET"
mdimport "$TARGET" 2>/dev/null || true
echo "→ installed $TARGET"

open "$TARGET"
