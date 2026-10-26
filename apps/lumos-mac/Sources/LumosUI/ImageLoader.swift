import AppKit
import ImageIO
import LumosCore
import SwiftUI

/// Pictures for cards and the inspector: downloaded once (URLCache keeps
/// them on disk), decoded once at the size they are shown, and kept in
/// memory, so scrolling back or reopening a page never downloads or decodes
/// again. SwiftUI's AsyncImage keeps nothing between views, which made rows
/// flicker and stutter.
@MainActor
public final class ImageLoader {
    public static let shared = ImageLoader()

    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [NSString: Task<Decoded?, Never>] = [:]
    private let session: URLSession

    init() {
        memory.totalCostLimit = 256 << 20
        let config = URLSessionConfiguration.default
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Burrow/images", isDirectory: true)
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 512 << 20, directory: directory)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    private func key(_ url: URL, _ maxPixels: Int) -> NSString { "\(maxPixels)|\(url.absoluteString)" as NSString }

    /// What is already decoded, without waiting; a view starts with it so
    /// nothing flashes.
    public func cached(_ url: URL, maxPixels: Int) -> NSImage? {
        memory.object(forKey: key(url, maxPixels))
    }

    public func image(_ url: URL, maxPixels: Int) async -> NSImage? {
        let key = key(url, maxPixels)
        if let hit = memory.object(forKey: key) { return hit }
        let task = inFlight[key] ?? Task<Decoded?, Never> { [session] in
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
            return await Self.decode(data, maxPixels: maxPixels)
        }
        inFlight[key] = task
        let decoded = await task.value
        inFlight[key] = nil
        guard let image = decoded?.image else { return nil }
        memory.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height) * 4)
        return image
    }

    /// Warms the cache for cards that are about to scroll into view.
    public func prefetch(_ urls: [URL], maxPixels: Int) {
        for url in urls where cached(url, maxPixels: maxPixels) == nil && inFlight[key(url, maxPixels)] == nil {
            Task(priority: .utility) { _ = await image(url, maxPixels: maxPixels) }
        }
    }

    /// Everything a row shows, posters and stills, at the sizes the cards use.
    public func prefetch(rows: [TitleRow], limit: Int = 24) {
        for row in rows {
            let items = row.items.prefix(limit)
            if row.style == .wide {
                prefetch(items.compactMap { ($0.backdrop ?? $0.poster).flatMap(URL.init(string:)) }, maxPixels: Artwork.widePixels)
            } else {
                prefetch(items.compactMap { $0.poster.flatMap(URL.init(string:)) }, maxPixels: Artwork.posterPixels)
            }
        }
    }

    /// NSImage is not Sendable; the decoded picture crosses from the decoding
    /// task to the main actor in this box and is not touched elsewhere.
    struct Decoded: @unchecked Sendable {
        let image: NSImage
    }

    /// Decodes off the main thread, downsampled to what the screen needs,
    /// with the pixels ready so the first draw does not decode again.
    nonisolated static func decode(_ data: Data, maxPixels: Int) async -> Decoded? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return Decoded(image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
        }.value
    }
}

/// A picture from the cache, or the placeholder until it is there.
public struct CachedImage<Placeholder: View>: View {
    let url: URL?
    let maxPixels: Int
    let placeholder: Placeholder
    @State private var image: NSImage?

    public init(url: URL?, maxPixels: Int, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.maxPixels = maxPixels
        self.placeholder = placeholder()
        _image = State(initialValue: url.flatMap { ImageLoader.shared.cached($0, maxPixels: maxPixels) })
    }

    public var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = ImageLoader.shared.cached(url, maxPixels: maxPixels) { image = hit; return }
            image = nil
            let loaded = await ImageLoader.shared.image(url, maxPixels: maxPixels)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { image = loaded }
        }
    }
}
