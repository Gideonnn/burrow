#!/usr/bin/env bash
# Builds Hedwig.app from the Swift package, without an Xcode project.
#
#   ./apps/hedwig-mac/scripts/bundle.sh            release build in apps/hedwig-mac/build/
#
# The icon comes from Resources/AppIcon.icns (regenerate it with make-icon.sh).
# Signed with the "Burrow Hedwig" identity when it exists, otherwise ad hoc;
# ad hoc makes macOS ask for Keychain access again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${HEDWIG_VERSION:-0.1.0}"
# The build number decides updates: a Hedwig installs a published build only
# when its number is higher. The commit count on main only grows.
BUILD="${HEDWIG_BUILD:-$(git rev-list --count HEAD)}"
APP="build/Hedwig.app"

swift build -c release --product Hedwig
BIN="$(swift build -c release --show-bin-path)/Hedwig"

/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp -f "$BIN" "$APP/Contents/MacOS/Hedwig"
/bin/cp -f Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hedwig</string>
  <key>CFBundleDisplayName</key><string>Hedwig</string>
  <key>CFBundleIdentifier</key><string>app.burrow.hedwig</string>
  <key>CFBundleExecutable</key><string>Hedwig</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleDevelopmentRegion</key><string>nl</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# A fixed identity (scripts/signing-identity.sh) keeps the keychain from asking
# again after every update; without it the app is signed ad hoc.
IDENTITY="${HEDWIG_SIGN_IDENTITY:-Burrow Hedwig}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null
else
  codesign --force --sign - "$APP" >/dev/null
fi
echo "built $(pwd)/$APP"
