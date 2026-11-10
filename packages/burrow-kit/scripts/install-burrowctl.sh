#!/usr/bin/env bash
# Builds burrowctl and installs it in ~/.local/bin, signed like the apps so the
# keychain keeps trusting the runner. Every Mac app's install script calls this.
#
# The new binary goes in under a temporary name and is then moved over the old
# one: copying onto the existing file keeps its inode, and macOS kills the
# changed binary on launch (exit 137) because it still holds the old signature.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product burrowctl >/dev/null
mkdir -p "$HOME/.local/bin"
tmp="$(mktemp "$HOME/.local/bin/.burrowctl.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
/bin/cp -f "$(swift build -c release --show-bin-path)/burrowctl" "$tmp"
chmod 755 "$tmp"
./scripts/sign-app.sh "$tmp" >/dev/null
mv -f "$tmp" "$HOME/.local/bin/burrowctl"
echo "→ installed ~/.local/bin/burrowctl"
