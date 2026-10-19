#!/usr/bin/env bash
# Builds Pensieve and installs it in /Applications, so Spotlight, Launchpad and
# Raycast find it:
#
#   pnpm pensieve:install
#
# Quits a running Pensieve first (asking if it is recording) and starts the
# new one afterwards. Also installs burrowctl in ~/.local/bin, the CLI and MCP
# server agents use to operate the Burrow apps.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="/Applications/Pensieve.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

./scripts/bundle.sh >/dev/null
echo "→ built build/Pensieve.app"

(cd ../../packages/burrow-kit && swift build -c release --product burrowctl >/dev/null \
  && mkdir -p "$HOME/.local/bin" \
  && /bin/cp -f "$(swift build -c release --show-bin-path)/burrowctl" "$HOME/.local/bin/burrowctl")
echo "→ installed ~/.local/bin/burrowctl"

if pgrep -xq Pensieve; then
  osascript -e 'tell application "Pensieve" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -xq Pensieve || break; sleep 0.2; done
  pgrep -xq Pensieve && { echo "✗ Pensieve is still running (recording?); stop it first" >&2; exit 1; }
fi

/bin/rm -rf "$TARGET"
/bin/mv build/Pensieve.app "$TARGET"
"$LSREGISTER" -f "$TARGET"
mdimport "$TARGET" 2>/dev/null || true
echo "→ installed $TARGET"

open "$TARGET"
