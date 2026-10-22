import Foundation
import PensieveMedia

/// "Verklein video" for any video, also from outside Pensieve (an iPhone
/// `.mov`): the sheet's options with their estimated sizes, and the shrink
/// itself, saved next to the original, which stays.
public struct VideoShrink: Sendable {
    let shrinker: Shrinker

    public init(encoder: VideoEncoder = AssetWriterEncoder(), probe: MediaProbing = AVProbe()) {
        shrinker = Shrinker(encoder: encoder, probe: probe)
    }

    public func options(for original: URL, limit: Int64? = nil) async throws -> (source: VideoSource, options: [ShrinkOption]) {
        let source = try await shrinker.probe.source(of: original)
        return (source, ShrinkPlanner.options(source: source, limit: limit))
    }

    /// "presentatie-aardrijkskunde-720p.mp4" next to it, or "-720p-2.mp4"
    /// when that name is taken.
    public static func output(for original: URL, height: Int) -> URL {
        let dir = original.deletingLastPathComponent()
        let name = Naming.shrunk(original: original, height: height)
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name.dropLast(4))-\(n).mp4")
            n += 1
        }
        return candidate
    }

    public func shrink(
        _ original: URL, quality: ShrinkQuality, limit: Int64? = nil, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Shrinker.Outcome {
        let source = try await shrinker.probe.source(of: original)
        guard case .encode(let settings) = ShrinkPlanner.plan(source: source, quality: quality, limit: limit) else {
            return .alreadySmall(bytes: source.bytes)
        }
        let output = Self.output(for: original, height: settings.height)
        return .shrunk(try await shrinker.encode(original, to: output, quality: quality, limit: limit, source: source, progress: progress))
    }
}
