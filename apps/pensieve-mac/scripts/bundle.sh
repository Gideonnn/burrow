#!/usr/bin/env bash
# Builds Pensieve.app from the Swift package, without an Xcode project.
#
#   ./apps/pensieve-mac/scripts/bundle.sh          release build in apps/pensieve-mac/build/
#
# The icon comes from Resources/AppIcon.icns (regenerate it with make-icon.sh).
# Signed by packages/burrow-kit/scripts/sign-app.sh, which picks an identity with an
# Apple team ID when there is one, so the keychain keeps trusting new builds.
# A steady identity also keeps the microphone and system audio grants across updates.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${APP_VERSION:-0.1.0}"
# The build number decides updates: Pensieve installs a published build only
# when its number is higher. The commit count on main only grows.
BUILD="${APP_BUILD:-$(git rev-list --count HEAD)}"
APP="build/Pensieve.app"

swift build -c release --product Pensieve
BIN="$(swift build -c release --show-bin-path)/Pensieve"

/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp -f "$BIN" "$APP/Contents/MacOS/Pensieve"
/bin/cp -f Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pensieve</string>
  <key>CFBundleDisplayName</key><string>Pensieve</string>
  <key>CFBundleIdentifier</key><string>app.burrow.pensieve</string>
  <key>CFBundleExecutable</key><string>Pensieve</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleDevelopmentRegion</key><string>nl</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>Pensieve neemt jouw kant van het gesprek op.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Pensieve neemt de andere kant van het gesprek op: wat de Mac afspeelt.</string>
  <key>NSCameraUsageDescription</key><string>Pensieve neemt video op met je camera, bijvoorbeeld voor een interview.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

../../packages/burrow-kit/scripts/sign-app.sh "$APP"
echo "built $(pwd)/$APP"
