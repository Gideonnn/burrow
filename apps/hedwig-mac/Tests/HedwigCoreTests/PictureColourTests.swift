import CoreGraphics
import Testing
@testable import HedwigCore

@Suite struct PictureColourTests {
    private static func image(_ stripes: [(red: Double, green: Double, blue: Double)]) -> CGImage {
        let width = 90 * stripes.count
        let context = CGContext(
            data: nil, width: width, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (index, stripe) in stripes.enumerated() {
            context.setFillColor(CGColor(red: stripe.red, green: stripe.green, blue: stripe.blue, alpha: 1))
            context.fill(CGRect(x: index * 90, y: 0, width: 90, height: 60))
        }
        return context.makeImage()!
    }

    @Test func hslRoundTrips() {
        let orange = HSL(red: 1, green: 0.5, blue: 0)
        #expect(abs(orange.hue - 30) < 0.5 && abs(orange.saturation - 1) < 0.01 && abs(orange.lightness - 0.5) < 0.01)
        let back = orange.rgb
        #expect(abs(back.red - 1) < 0.01 && abs(back.green - 0.5) < 0.01 && back.blue < 0.01)
    }

    @Test func greyMiddlesDoNotCount() {
        let colours = PictureColours.dominant(Self.image([(0.9, 0.1, 0.1), (0.5, 0.5, 0.5), (0.1, 0.2, 0.9)]))
        #expect(colours.count == 2)
        #expect(colours.allSatisfy { $0.saturation > 0.5 })
        #expect(colours.contains { $0.hue < 15 || $0.hue > 345 } && colours.contains { (200...250).contains($0.hue) })
    }

    @Test func backdropsKeepTextReadable() {
        let colours = PictureColours.dominant(Self.image([(0.5, 0.5, 0.5)]))
        #expect(colours == [HSL(hue: 0, saturation: 0, lightness: 0.5)])
        let light = PictureColours.backdrop([HSL(hue: 20, saturation: 0.9, lightness: 0.3)], dark: false)
        #expect(light.first?.lightness ?? 0 > 0.8)
        #expect(PictureColours.backdrop(light, dark: true).first?.lightness ?? 1 < 0.3)
    }
}
