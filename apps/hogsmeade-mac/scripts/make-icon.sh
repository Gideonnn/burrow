#!/usr/bin/env bash
# Draws the two icons: Resources/AppIcon.icns (the native face: a violet tile
# with a signpost, like the one in the village you may visit on Saturdays) and
# Resources/AppIconFeest.icns (the playful face: a night tile with a party
# popper in lemon). From SF Symbols through CoreGraphics and iconutil.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap '/bin/rm -rf "$work"' EXIT

cat > "$work/draw.swift" <<'SWIFT'
import AppKit
let out = CommandLine.arguments[1]
let face = CommandLine.arguments[2]
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                            xRadius: s * 0.22, yRadius: s * 0.22)
    let colours: [NSColor] = face == "feest"
        ? [NSColor(srgbRed: 0.36, green: 0.17, blue: 0.66, alpha: 1), NSColor(srgbRed: 0.08, green: 0.06, blue: 0.16, alpha: 1)]
        : [NSColor(srgbRed: 0.61, green: 0.36, blue: 0.94, alpha: 1), NSColor(srgbRed: 0.36, green: 0.16, blue: 0.66, alpha: 1)]
    NSGradient(colors: colours)!.draw(in: tile, angle: -70)
    if face == "feest" {
        // A few confetti pieces behind the popper.
        let pieces: [(CGFloat, CGFloat, NSColor)] = [
            (0.26, 0.72, NSColor(srgbRed: 0.96, green: 0.83, blue: 0.36, alpha: 1)), (0.70, 0.78, NSColor(srgbRed: 0.56, green: 0.86, blue: 0.75, alpha: 1)),
            (0.78, 0.40, NSColor(srgbRed: 0.55, green: 0.78, blue: 0.94, alpha: 1)), (0.30, 0.34, NSColor(srgbRed: 0.96, green: 0.61, blue: 0.76, alpha: 1)),
            (0.60, 0.26, NSColor(srgbRed: 0.97, green: 0.70, blue: 0.54, alpha: 1)),
        ]
        for (x, y, colour) in pieces {
            colour.setFill()
            let piece = NSBezierPath(roundedRect: NSRect(x: s * x, y: s * y, width: s * 0.06, height: s * 0.09), xRadius: s * 0.012, yRadius: s * 0.012)
            let turn = NSAffineTransform()
            turn.translateX(by: s * x + s * 0.03, yBy: s * y + s * 0.045)
            turn.rotate(byDegrees: CGFloat((x * 100).truncatingRemainder(dividingBy: 60)) - 30)
            turn.translateX(by: -(s * x + s * 0.03), yBy: -(s * y + s * 0.045))
            piece.transform(using: turn as AffineTransform)
            piece.fill()
        }
    }
    let symbolName = face == "feest" ? "party.popper.fill" : "signpost.right.fill"
    let tint = face == "feest" ? NSColor(srgbRed: 0.96, green: 0.83, blue: 0.36, alpha: 1) : NSColor.white
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold).applying(.init(paletteColors: [tint]))
    if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let r = NSRect(x: (s - symbol.size.width) / 2, y: (s - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
        symbol.draw(in: r)
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(size).png"))
}
SWIFT
swiftc -O "$work/draw.swift" -o "$work/draw" >/dev/null

for face in native feest; do
  dir="$work/$face"
  iconset="$dir/AppIcon.iconset"
  mkdir -p "$iconset"
  "$work/draw" "$dir" "$face"
  for size in 16 32 128 256 512; do
    /bin/cp -f "$dir/$size.png" "$iconset/icon_${size}x${size}.png"
    /bin/cp -f "$dir/$((size * 2)).png" "$iconset/icon_${size}x${size}@2x.png"
  done
  target="Resources/AppIcon.icns"
  [ "$face" = feest ] && target="Resources/AppIconFeest.icns"
  iconutil -c icns "$iconset" -o "$target"
  echo "wrote $target"
done
