import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The picture with an outing (docs/design/hedwig-event-images.html): how it
// is shown, the colours without one, and what a paste or drop becomes.

/// A colour as hue (degrees), saturation and lightness (0...1), as in CSS `hsl()`.
public struct HSL: Hashable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var lightness: Double

    public init(hue: Double, saturation: Double, lightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }

    public var rgb: (red: Double, green: Double, blue: Double) {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let h = hue.truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) =
            switch h {
            case ..<1: (c, x, 0)
            case ..<2: (x, c, 0)
            case ..<3: (0, c, x)
            case ..<4: (0, x, c)
            case ..<5: (x, 0, c)
            default: (c, 0, x)
            }
        let m = lightness - c / 2
        return (r + m, g + m, b + m)
    }
}

/// The calm colours for an outing without a picture: always the same for the
/// same title, and dark enough for white text without a scrim.
public struct TitleColours: Hashable, Sendable {
    public var start: HSL
    public var end: HSL
    public var glow: HSL

    public init(title: String) {
        let hue = Double(Self.hash(title) % 360)
        start = HSL(hue: hue, saturation: 0.40, lightness: 0.30)
        end = HSL(hue: (hue + 40).truncatingRemainder(dividingBy: 360), saturation: 0.46, lightness: 0.20)
        glow = HSL(hue: (hue + 20).truncatingRemainder(dividingBy: 360), saturation: 0.55, lightness: 0.46)
    }

    /// The design's hash, so the Mac shows the colours the design shows.
    static func hash(_ text: String) -> UInt32 {
        text.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value }
    }
}

/// Whether a picture fills the band or is shown sharp at its own size over a
/// blurred copy of itself. Small or square pictures are never stretched.
public enum PictureFit: Sendable {
    case fill
    case framed

    public init(width: Int, height: Int) {
        self = width >= 1000 && height > 0 && Double(width) / Double(height) >= 4.0 / 3.0 ? .fill : .framed
    }
}

/// A picture ready to draw, with its size in pixels.
public struct OutingPicture: @unchecked Sendable {
    public let image: CGImage
    public var width: Int { image.width }
    public var height: Int { image.height }
    public var fit: PictureFit { PictureFit(width: width, height: height) }

    public init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        self.image = image
    }
}

// MARK: Paste and drop

/// What was on the pasteboard or dropped, in plain values, so the choice is
/// testable without a window.
public struct PastedContents: Sendable {
    public var fileURLs: [URL] = []
    /// Image bytes in any format ImageIO reads (Safari and Mail put TIFF).
    public var images: [Data] = []
    public var urls: [URL] = []
    public var strings: [String] = []

    public init(fileURLs: [URL] = [], images: [Data] = [], urls: [URL] = [], strings: [String] = []) {
        self.fileURLs = fileURLs
        self.images = images
        self.urls = urls
        self.strings = strings
    }

    public var isEmpty: Bool { fileURLs.isEmpty && images.isEmpty && urls.isEmpty && strings.isEmpty }
}

/// What a paste or drop becomes: bytes or a file to upload, or a link the
/// server follows to a picture or to a page with a share picture.
public enum PastedPicture: Equatable, Sendable {
    case image(Data)
    case file(URL)
    case link(URL)

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]

    public init?(_ contents: PastedContents) {
        // Finder puts a file's icon next to the file: the file wins, and a
        // copied pdf is no picture at all.
        if !contents.fileURLs.isEmpty {
            guard let file = contents.fileURLs.first(where: { Self.imageExtensions.contains($0.pathExtension.lowercased()) })
            else { return nil }
            self = .file(file)
        } else if let data = contents.images.first(where: { !$0.isEmpty }) {
            self = .image(data)
        } else if let url = contents.urls.first(where: Self.isWeb) ?? contents.strings.lazy.compactMap(Self.link).first {
            self = .link(url)
        } else {
            return nil
        }
    }

    static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
    }

    /// Only a string that is one address, not a sentence with one in it.
    static func link(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), isWeb(url) else { return nil }
        return url
    }
}

extension PastedContents {
    public static let dropTypes: [UTType] = [.fileURL, .image, .url, .plainText]

    /// Reads dropped items: files first, then image bytes, links and text.
    /// Runs on the caller's actor because `NSItemProvider` is not Sendable.
    public nonisolated(nonsending) static func load(_ providers: [NSItemProvider]) async -> PastedContents {
        var contents = PastedContents()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await provider.load(URL.self), url.isFileURL { contents.fileURLs.append(url) }
                continue
            }
            if let type = provider.registeredTypeIdentifiers.compactMap({ UTType($0) }).first(where: { $0.conforms(to: .image) }),
               let data = await provider.loadData(type) {
                contents.images.append(data)
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = await provider.load(URL.self) {
                if url.isFileURL { contents.fileURLs.append(url) } else { contents.urls.append(url) }
            } else if provider.canLoadObject(ofClass: String.self), let text = await provider.load(String.self) {
                contents.strings.append(text)
            }
        }
        return contents
    }
}

extension NSItemProvider {
    fileprivate nonisolated(nonsending) func loadData(_ type: UTType) async -> Data? {
        await withCheckedContinuation { done in
            _ = loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in done.resume(returning: data) }
        }
    }

    fileprivate nonisolated(nonsending) func load<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type) async -> T? where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { done in
            _ = loadObject(ofClass: type) { value, _ in done.resume(returning: value) }
        }
    }
}

// MARK: Upload

public enum PictureUpload {
    /// The server keeps at most this much.
    public static let maxBytes = 8 * 1024 * 1024

    /// Bytes the server accepts: PNG, JPEG, GIF and WebP as they are, anything
    /// else ImageIO reads (TIFF from Safari, HEIC from Photos) as JPEG or PNG,
    /// scaled down when it would be too large. Nil when it is no picture.
    public static func prepare(_ data: Data) -> (data: Data, fileExtension: String)? {
        if let ext = served(data), data.count <= maxBytes { return (data, ext) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        for side in [nil, 2400, 1600] as [Int?] {
            guard let image = thumbnail(source, maxSide: side) else { return nil }
            let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
            let type = alpha ? UTType.png : .jpeg
            guard let encoded = encode(image, type: type) else { return nil }
            if encoded.count <= maxBytes { return (encoded, alpha ? "png" : "jpg") }
        }
        return nil
    }

    /// The extension of a format the server shows, by its first bytes.
    static func served(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: Array("GIF8".utf8)) { return "gif" }
        if b.count >= 12, b.starts(with: Array("RIFF".utf8)), Array(b[8..<12]) == Array("WEBP".utf8) { return "webp" }
        return nil
    }

    private static func thumbnail(_ source: CGImageSource, maxSide: Int?) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if let maxSide { options[kCGImageSourceThumbnailMaxPixelSize] = maxSide } else {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
            else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
            options[kCGImageSourceThumbnailMaxPixelSize] = max(w, h)
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encode(_ image: CGImage, type: UTType) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

// MARK: Backdrop colours

/// The few strong colours of a picture, for a backdrop with the picture's
/// mood but without the grey a blurred copy smears in the middle.
public enum PictureColours {
    /// Up to `count` colours, the most present first; grey, near black and
    /// near white pixels do not count. A picture without colour gives one grey.
    public static func dominant(_ image: CGImage, count: Int = 3) -> [HSL] {
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        var bins: [Int: (weight: Double, r: Double, g: Double, b: Double)] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 128 {
            let (r, g, b) = (Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255)
            let colour = HSL(red: r, green: g, blue: b)
            guard colour.saturation > 0.18, (0.1...0.92).contains(colour.lightness) else { continue }
            let bin = Int(colour.hue / 30) % 12
            let weight = colour.saturation
            let old = bins[bin] ?? (0, 0, 0, 0)
            bins[bin] = (old.weight + weight, old.r + r * weight, old.g + g * weight, old.b + b * weight)
        }
        let strongest = bins.values.sorted { $0.weight > $1.weight }.prefix(count)
        guard !strongest.isEmpty else { return [HSL(hue: 0, saturation: 0, lightness: 0.5)] }
        return strongest.map { HSL(red: $0.r / $0.weight, green: $0.g / $0.weight, blue: $0.b / $0.weight) }
    }

    /// Light enough for black text in light mode, deep enough for white in dark.
    public static func backdrop(_ colours: [HSL], dark: Bool) -> [HSL] {
        colours.map { colour in
            let saturation = colour.saturation < 0.05 ? 0 : min(max(colour.saturation, 0.45), 0.8)
            return HSL(hue: colour.hue, saturation: saturation, lightness: dark ? 0.24 : 0.87)
        }
    }
}

extension HSL {
    public init(red: Double, green: Double, blue: Double) {
        let high = max(red, green, blue), low = min(red, green, blue)
        let lightness = (high + low) / 2
        guard high > low else {
            self.init(hue: 0, saturation: 0, lightness: lightness)
            return
        }
        let delta = high - low
        var hue: Double =
            switch high {
            case red: ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            case green: (blue - red) / delta + 2
            default: (red - green) / delta + 4
            }
        hue *= 60
        if hue < 0 { hue += 360 }
        self.init(hue: hue, saturation: min(1, delta / (1 - abs(2 * lightness - 1))), lightness: lightness)
    }
}
