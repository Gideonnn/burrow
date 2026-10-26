#!/usr/bin/env bash
# Draws Resources/AppIcon.icns: Lumos's purple tile with a spark of light,
# from an SF Symbol, through CoreGraphics and iconutil. Run after changing it.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap '/bin/rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"

cat > "$work/draw.swift" <<'SWIFT'
import AppKit
let out = CommandLine.arguments[1]
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                            xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(srgbRed: 0.55, green: 0.43, blue: 0.64, alpha: 1),
                        NSColor(srgbRed: 0.30, green: 0.22, blue: 0.37, alpha: 1)])!.draw(in: tile, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .medium)
        .applying(.init(paletteColors: [NSColor(srgbRed: 1, green: 0.93, blue: 0.75, alpha: 1)]))
    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let r = NSRect(x: (s - symbol.size.width) / 2, y: (s - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
        symbol.draw(in: r)
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(size).png"))
}
SWIFT
swiftc -O "$work/draw.swift" -o "$work/draw" >/dev/null && "$work/draw" "$work"

for size in 16 32 128 256 512; do
  /bin/cp -f "$work/$size.png" "$iconset/icon_${size}x${size}.png"
  /bin/cp -f "$work/$((size * 2)).png" "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
