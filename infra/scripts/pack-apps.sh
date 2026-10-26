#!/usr/bin/env bash
# Puts the latest built apps in one zip on the Desktop, for a Mac that has
# none of them yet (AirDrop it, unzip, drag to Programma's, log in through the
# device login in each app). From then on every app updates itself from Dobby.
#
#   pnpm apps:pack            after pnpm <app>:release (or <app>:install) of each app
#
# The apps come from each package's build/ folder, so they are the builds that
# were just released or installed, signed the same way.
set -euo pipefail
cd "$(dirname "$0")/../.."

apps=(
  "apps/hedwig-mac/build/Hedwig.app"
  "apps/pensieve-mac/build/Pensieve.app"
  "apps/lumos-mac/build/Lumos.app"
  "apps/hogsmeade-mac/build/Hogsmeade.app"
  "apps/hogsmeade-mac/build/Hogsmeade Feest.app"
)
stage="$(mktemp -d)/Burrow apps"
mkdir -p "$stage"
for app in "${apps[@]}"; do
  if [ -d "$app" ]; then
    /bin/cp -R "$app" "$stage/"
    echo "→ $(basename "$app") build $(defaults read "$PWD/$app/Contents/Info.plist" CFBundleVersion)"
  else
    echo "✗ $app is not built; run its install or release first" >&2
    exit 1
  fi
done
cat > "$stage/Lees mij.txt" <<'TXT'
Burrow op een nieuwe Mac

1. Sleep de apps naar Programma's.
2. Open een app; kies "Inloggen op deze Mac" en maak het af op je eigen Mac of telefoon.
3. Elke app haalt daarna zelf nieuwe versies op en toont "Update klaar · Herstart".

Hogsmeade en Hogsmeade Feest zijn hetzelfde uitjesboek in twee gezichten; kies welke je
leuker vindt, de andere mag weg.
TXT
out="$HOME/Desktop/Burrow apps.zip"
rm -f "$out"
ditto -c -k --keepParent "$stage" "$out"
echo "→ $out ($(du -h "$out" | cut -f1))"
