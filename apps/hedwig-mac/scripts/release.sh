#!/usr/bin/env bash
# Publishes the current commit of Hedwig to every Mac in the household:
#
#   pnpm hedwig:release
#
# Builds with the commit count as build number, signs the zip with the release
# key from SOPS and copies it to Dobby, where the server offers it. Each Hedwig
# checks the signature, gets the build ready and shows "Update klaar". For
# trying things on this Mac only, use pnpm hedwig:install instead.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(cd ../.. && pwd)"
HOST="${DOBBY:-dobby}"
DIR=".local/share/burrow/clients/hedwig"

fail() { echo "✗ $*" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || fail "commit first: a release is built from a commit"
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "push first: a release is built from origin/main"

BUILD="$(git rev-list --count HEAD)"
echo "→ building Hedwig build $BUILD"
HEDWIG_BUILD="$BUILD" ./scripts/bundle.sh >/dev/null
ZIP="build/Hedwig-$BUILD.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Hedwig.app "$ZIP"

echo "→ signing"
"$REPO/infra/scripts/with-secrets.sh" tools node scripts/sign-release.mjs "$ZIP" "$BUILD" \
  >build/latest.json 2>build/release-public-key
grep -qF "\"$(cat build/release-public-key)\"" Sources/HedwigCore/Update/ReleaseKey.swift \
  || fail "the key in SOPS does not match ReleaseKey.swift; Hedwig would refuse this build"

echo "→ publishing on $HOST"
ssh "$HOST" "mkdir -p $DIR"
scp -q "$ZIP" "$HOST:$DIR/$BUILD.zip"
scp -q build/latest.json "$HOST:$DIR/latest.json.tmp"
# latest.json moves last, so a client never sees a build that is not there yet;
# the three newest builds stay.
ssh "$HOST" "cd $DIR && mv latest.json.tmp latest.json && ls -t *.zip | tail -n +4 | xargs -r rm --"
echo "→ published build $BUILD; every Hedwig picks it up within the hour (hedwigctl update for now)"
