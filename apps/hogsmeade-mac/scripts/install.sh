#!/usr/bin/env bash
# Builds one face of Hogsmeade and installs it in /Applications, so Spotlight,
# Launchpad and Raycast find it:
#
#   pnpm hogsmeade:install          the native face
#   pnpm hogsmeade:install:feest    the playful face
#
# Quits a running copy first and starts the new one afterwards. Also installs
# burrowctl in ~/.local/bin, the CLI and MCP server agents use to operate the
# Burrow apps.
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCT="${1:-Hogsmeade}"
case "$PRODUCT" in
  Hogsmeade) NAME="Hogsmeade" ;;
  HogsmeadeFeest) NAME="Hogsmeade Feest" ;;
  *) echo "✗ product is Hogsmeade or HogsmeadeFeest" >&2; exit 2 ;;
esac
TARGET="/Applications/$NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

./scripts/bundle.sh "$PRODUCT" >/dev/null
echo "→ built build/$NAME.app"

(cd ../../packages/burrow-kit && swift build -c release --product burrowctl >/dev/null \
  && mkdir -p "$HOME/.local/bin" \
  && /bin/cp -f "$(swift build -c release --show-bin-path)/burrowctl" "$HOME/.local/bin/burrowctl")
echo "→ installed ~/.local/bin/burrowctl"

if pgrep -xq "$PRODUCT"; then
  osascript -e "tell application \"$NAME\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -xq "$PRODUCT" || break; sleep 0.2; done
  pgrep -xq "$PRODUCT" && { echo "✗ $NAME is still running; stop it first" >&2; exit 1; }
fi

/bin/rm -rf "$TARGET"
/bin/mv "build/$NAME.app" "$TARGET"
"$LSREGISTER" -f "$TARGET"
mdimport "$TARGET" 2>/dev/null || true
echo "→ installed $TARGET"

open "$TARGET"
