#!/usr/bin/env bash
# Builds one face of Hogsmeade as an app bundle, without an Xcode project:
#
#   ./apps/hogsmeade-mac/scripts/bundle.sh                 Hogsmeade.app (the native face)
#   ./apps/hogsmeade-mac/scripts/bundle.sh HogsmeadeFeest  Hogsmeade Feest.app (the playful face)
#
# Both come from one package and one model; they differ in the executable,
# the bundle id, the icon and the update channel, so they run side by side.
# Signed by packages/burrow-kit/scripts/sign-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCT="${1:-${BUNDLE_PRODUCT:-Hogsmeade}}"
case "$PRODUCT" in
  Hogsmeade) NAME="Hogsmeade"; ID="app.burrow.hogsmeade"; ICON="AppIcon" ;;
  HogsmeadeFeest) NAME="Hogsmeade Feest"; ID="app.burrow.hogsmeade-feest"; ICON="AppIconFeest" ;;
  *) echo "✗ product is Hogsmeade or HogsmeadeFeest" >&2; exit 2 ;;
esac

VERSION="${APP_VERSION:-0.1.0}"
# The build number decides updates: a published build is installed only when
# its number is higher. The commit count on main only grows.
BUILD="${APP_BUILD:-$(git rev-list --count HEAD)}"
APP="build/$NAME.app"

swift build -c release --product "$PRODUCT"
BIN="$(swift build -c release --show-bin-path)/$PRODUCT"

/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp -f "$BIN" "$APP/Contents/MacOS/$PRODUCT"
/bin/cp -f "Resources/$ICON.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${NAME}</string>
  <key>CFBundleDisplayName</key><string>${NAME}</string>
  <key>CFBundleIdentifier</key><string>${ID}</string>
  <key>CFBundleExecutable</key><string>${PRODUCT}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleDevelopmentRegion</key><string>nl</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.lifestyle</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocationUsageDescription</key><string>${NAME} gebruikt je locatie alleen om de reistijd naar een uitje te tonen; Burrow krijgt hem niet.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}" ../../packages/burrow-kit/scripts/sign-app.sh "$APP"
echo "built $(pwd)/$APP"
