#!/usr/bin/env bash
# Builds Lumos.app from the Swift package, without an Xcode project.
#
#   ./apps/lumos-mac/scripts/bundle.sh          release build in apps/lumos-mac/build/
#
# The icon comes from Resources/AppIcon.icns (drawn by make-icon.sh).
# Signed by packages/burrow-kit/scripts/sign-app.sh, which picks an identity with an
# Apple team ID when there is one, so the keychain keeps trusting new builds.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${APP_VERSION:-0.1.0}"
# The build number decides updates: Lumos installs a published build only
# when its number is higher. The commit count on main only grows.
BUILD="${APP_BUILD:-$(git rev-list --count HEAD)}"
APP="build/Lumos.app"

swift build -c release --product Lumos
BIN="$(swift build -c release --show-bin-path)/Lumos"

/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp -f "$BIN" "$APP/Contents/MacOS/Lumos"
/bin/cp -f Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lumos</string>
  <key>CFBundleDisplayName</key><string>Lumos</string>
  <key>CFBundleIdentifier</key><string>app.burrow.lumos</string>
  <key>CFBundleExecutable</key><string>Lumos</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleDevelopmentRegion</key><string>nl</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

../../packages/burrow-kit/scripts/sign-app.sh "$APP"
echo "built $(pwd)/$APP"
