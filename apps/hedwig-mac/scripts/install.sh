#!/usr/bin/env bash
# Builds Hedwig and installs it in /Applications, so Spotlight, Launchpad and
# Raycast find it:
#
#   ./apps/hedwig-mac/scripts/install.sh
#
# Quits a running Hedwig first and starts the new one afterwards. In Raycast,
# give Hedwig the alias "email" (Raycast Settings › Extensions › Applications).
# Also installs hedwigctl, the CLI agents use to operate Hedwig, in ~/.local/bin.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="/Applications/Hedwig.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

./scripts/bundle.sh >/dev/null
echo "→ built build/Hedwig.app"

swift build -c release --product hedwigctl >/dev/null
mkdir -p "$HOME/.local/bin"
/bin/cp -f "$(swift build -c release --show-bin-path)/hedwigctl" "$HOME/.local/bin/hedwigctl"
echo "→ installed ~/.local/bin/hedwigctl"

if pgrep -xq Hedwig; then
  osascript -e 'tell application "Hedwig" to quit' >/dev/null 2>&1 || pkill -x Hedwig || true
  sleep 1
fi

/bin/rm -rf "$TARGET"
/bin/mv build/Hedwig.app "$TARGET"  # moved, so Spotlight lists only one Hedwig
# Register with Launch Services and index it right away instead of waiting
# for Spotlight to notice the new app.
"$LSREGISTER" -f "$TARGET"
mdimport "$TARGET" 2>/dev/null || true
echo "→ installed $TARGET"

open "$TARGET"
