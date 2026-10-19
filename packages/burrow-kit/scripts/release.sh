#!/usr/bin/env bash
# Publishes the current commit of one Burrow app to every Mac in the household:
#
#   packages/burrow-kit/scripts/release.sh <app folder> <AppName> <client>
#   (pnpm hedwig:release, pnpm pensieve:release)
#
# Builds with the commit count as build number, signs the zip with the release
# key from SOPS and copies it to Dobby, where the server offers it. Each copy
# of the app checks the signature, gets the build ready and shows "Update
# klaar". For trying things on this Mac only, use the app's install script.
set -euo pipefail
APP_DIR="$(cd "$1" && pwd)"
NAME="$2"
CLIENT="$3"
KIT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$KIT/../.." && pwd)"
HOST="${DOBBY:-dobby}"
DIR=".local/share/burrow/clients/$CLIENT"

fail() { echo "✗ $*" >&2; exit 1; }
cd "$APP_DIR"
[ -z "$(git status --porcelain)" ] || fail "commit first: a release is built from a commit"
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "push first: a release is built from origin/main"

BUILD="$(git rev-list --count HEAD)"
echo "→ building $NAME build $BUILD"
APP_BUILD="$BUILD" ./scripts/bundle.sh >/dev/null
ZIP="build/$NAME-$BUILD.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "build/$NAME.app" "$ZIP"

echo "→ signing"
"$REPO/infra/scripts/with-secrets.sh" tools node "$KIT/scripts/sign-release.mjs" "$ZIP" "$BUILD" \
  >build/latest.json 2>build/release-public-key
grep -qF "\"$(cat build/release-public-key)\"" "$KIT/Sources/BurrowKit/Update/ReleaseKey.swift" \
  || fail "the key in SOPS does not match ReleaseKey.swift; $NAME would refuse this build"

echo "→ publishing on $HOST"
ssh "$HOST" "mkdir -p $DIR"
scp -q "$ZIP" "$HOST:$DIR/$BUILD.zip"
scp -q build/latest.json "$HOST:$DIR/latest.json.tmp"
# latest.json moves last, so a client never sees a build that is not there yet;
# the three newest builds stay.
ssh "$HOST" "cd $DIR && mv latest.json.tmp latest.json && ls -t *.zip | tail -n +4 | xargs -r rm --"
echo "→ published build $BUILD; every $NAME picks it up within the hour (burrowctl $CLIENT update for now)"
