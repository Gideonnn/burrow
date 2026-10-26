#!/usr/bin/env bash
# Builds Hogsmeade and installs it in /Applications, so Spotlight, Launchpad and
# Raycast find it:
#
#   pnpm hogsmeade:install
#
# Quits a running Hogsmeade first and starts the
# new one afterwards. Also installs burrowctl in ~/.local/bin, the CLI and MCP
# server agents use to operate the Burrow apps.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="/Applications/Hogsmeade.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

./scripts/bundle.sh >/dev/null
echo "→ built build/Hogsmeade.app"

(cd ../../packages/burrow-kit && swift build -c release --product burrowctl >/dev/null \
  && mkdir -p "$HOME/.local/bin" \
  && /bin/cp -f "$(swift build -c release --show-bin-path)/burrowctl" "$HOME/.local/bin/burrowctl")
echo "→ installed ~/.local/bin/burrowctl"

if pgrep -xq Hogsmeade; then
  osascript -e 'tell application "Hogsmeade" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -xq Hogsmeade || break; sleep 0.2; done
  pgrep -xq Hogsmeade && { echo "✗ Hogsmeade is still running; stop it first" >&2; exit 1; }
fi

/bin/rm -rf "$TARGET"
/bin/mv build/Hogsmeade.app "$TARGET"
"$LSREGISTER" -f "$TARGET"
mdimport "$TARGET" 2>/dev/null || true
echo "→ installed $TARGET"

open "$TARGET"
