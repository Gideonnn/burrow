import CoreGraphics
import Foundation

/// Where an outing's picture sits in the header: the point of the picture
/// (0 to 1 from the left and the top) that stands in the middle, and the zoom
/// on top of just filling the box. Shared with the household by the server.
public struct PictureFrame: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var zoom: Double

    public static let centred = PictureFrame(x: 0.5, y: 0.5, zoom: 1)
    public static let zooms: ClosedRange<Double> = 1...4

    public init(x: Double, y: Double, zoom: Double) {
        self.x = x
        self.y = y
        self.zoom = zoom
    }

    /// The picture's drawn size and its top-left corner in the box. The
    /// picture always covers the box: it never shows an empty edge.
    public func layout(image: CGSize, box: CGSize) -> (size: CGSize, origin: CGPoint) {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else {
            return (box, .zero)
        }
        let scale = max(box.width / image.width, box.height / image.height) * min(max(zoom, Self.zooms.lowerBound), Self.zooms.upperBound)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        let origin = CGPoint(
            x: min(0, max(box.width - size.width, box.width / 2 - x * size.width)),
            y: min(0, max(box.height - size.height, box.height / 2 - y * size.height)))
        return (size, origin)
    }

    /// The frame after the picture was dragged by `offset` points, as the
    /// box then really shows it (an edge stops the drag).
    public func dragged(by offset: CGSize, image: CGSize, box: CGSize) -> PictureFrame {
        let (size, origin) = layout(image: image, box: box)
        return PictureFrame(x: x, y: y, zoom: zoom)
            .showing(origin: CGPoint(x: origin.x + offset.width, y: origin.y + offset.height), size: size, image: image, box: box)
    }

    /// The frame zoomed to `zoom`, keeping what is in the middle there.
    public func zoomed(to zoom: Double, image: CGSize, box: CGSize) -> PictureFrame {
        let (size, origin) = layout(image: image, box: box)
        let middle = PictureFrame(
            x: (box.width / 2 - origin.x) / size.width,
            y: (box.height / 2 - origin.y) / size.height,
            zoom: min(max(zoom, Self.zooms.lowerBound), Self.zooms.upperBound))
        let (newSize, newOrigin) = middle.layout(image: image, box: box)
        return middle.showing(origin: newOrigin, size: newSize, image: image, box: box)
    }

    private func showing(origin: CGPoint, size: CGSize, image: CGSize, box: CGSize) -> PictureFrame {
        let clamped = CGPoint(
            x: min(0, max(box.width - size.width, origin.x)),
            y: min(0, max(box.height - size.height, origin.y)))
        return PictureFrame(
            x: Self.unit((box.width / 2 - clamped.x) / size.width),
            y: Self.unit((box.height / 2 - clamped.y) / size.height),
            zoom: zoom)
    }

    private static func unit(_ value: Double) -> Double {
        (min(1, max(0, value)) * 1000).rounded() / 1000
    }
}
