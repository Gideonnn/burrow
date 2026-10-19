#!/usr/bin/env bash
# Renders Resources/AppIcon.svg to Resources/AppIcon.icns with headless
# Chromium (through Playwright) and iconutil. Run after changing the SVG.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap '/bin/rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"

cat > "$work/render.mjs" <<'JS'
import { readFileSync } from 'node:fs';
import { chromium } from 'playwright';
const [svgPath, outDir] = process.argv.slice(2);
const svg = readFileSync(svgPath, 'utf8');
const browser = await chromium.launch();
const page = await browser.newPage();
for (const size of [16, 32, 64, 128, 256, 512, 1024]) {
  await page.setViewportSize({ width: size, height: size });
  await page.setContent(`<style>html,body{margin:0;background:transparent}svg{width:${size}px;height:${size}px;display:block}</style>${svg}`);
  await page.screenshot({ path: `${outDir}/${size}.png`, omitBackground: true });
}
await browser.close();
JS
( cd "$work" && echo '{"type":"module"}' > package.json && pnpm add playwright >/dev/null && node render.mjs "$OLDPWD/Resources/AppIcon.svg" "$work" )

for size in 16 32 128 256 512; do
  /bin/cp -f "$work/$size.png" "$iconset/icon_${size}x${size}.png"
  /bin/cp -f "$work/$((size * 2)).png" "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
