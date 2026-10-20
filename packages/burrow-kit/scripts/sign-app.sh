#!/usr/bin/env bash
# Signs an app bundle with the steadiest code signing identity on this Mac:
#
#   ./packages/burrow-kit/scripts/sign-app.sh apps/hedwig-mac/build/Hedwig.app
#
# The keychain only keeps "Sta altijd toe" across builds for apps with an Apple
# team ID. For any other signature, the self-made "Burrow Hedwig" included, it
# records the build's cdhash, so every update asks for the password again.
# Order: APP_SIGN_IDENTITY, a Developer ID Application or Apple Development
# certificate (a free Apple ID in Xcode gives the latter), "Burrow Hedwig", ad hoc.
set -euo pipefail
APP="$1"

identity="${APP_SIGN_IDENTITY:-}"
valid="$(security find-identity -v -p codesigning)"
for kind in "Developer ID Application" "Apple Development"; do
  [[ -n "$identity" ]] && break
  identity="$(sed -nE "s/.*\"($kind: [^\"]+)\".*/\1/p" <<<"$valid" | head -1)"
done
if [[ -z "$identity" ]] && security find-certificate -c "Burrow Hedwig" >/dev/null 2>&1; then
  identity="Burrow Hedwig"
fi
codesign --force --sign "${identity:--}" "$APP" >/dev/null
echo "signed with ${identity:-an ad hoc signature}"
