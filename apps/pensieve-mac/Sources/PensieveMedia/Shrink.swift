import Foundation

/// One line of the "Verklein video" sheet.
public struct ShrinkOption: Hashable, Sendable {
    public var quality: ShrinkQuality
    /// What the output will really be: never above the source.
    public var settings: EncodeSettings
    public var estimatedBytes: Int64
    public var bytesPerMinute: Int64
    /// False when the estimate does not fit 95 % of the limit ("te groot voor 25 MB").
    public var fits: Bool
}

public enum ShrinkPlan: Hashable, Sendable {
    /// The source is already this small or smaller; nothing to gain.
    case alreadySmall(bytes: Int64)
    case encode(EncodeSettings)
}

public enum ShrinkError: Error, LocalizedError, Equatable {
    case doesNotFit(limit: Int64)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .doesNotFit(let limit):
            "Deze video past niet in \(limit / 1_000_000) MB, ook niet op de kleinste stand. Knip hem korter of kies een ruimere limiet."
        case .unreadable: "Het verkleinde bestand speelt niet af; het origineel staat er nog."
        }
    }
}

/// Decides what "Verklein video" does with a source, a quality and an
/// optional size limit. Pure, so the sheet and the tests share it.
public enum ShrinkPlanner {
    /// The share of the limit a first encode aims for, leaving room for the
    /// encoder's spread.
    public static let targetShare = 0.95

    /// The quality's settings for this source: no upscaling, and a source
    /// smaller than the profile keeps the bitrate per pixel.
    public static func settings(for quality: ShrinkQuality, source: VideoSource) -> EncodeSettings {
        settings(for: quality.profile, source: source)
    }

    public static func settings(for profile: VideoProfile, source: VideoSource) -> EncodeSettings {
        let height = min(profile.height, source.shortSide > 0 ? source.shortSide : profile.height)
        let pixels = pow(Double(height) / Double(profile.height), 2)
        return EncodeSettings(
            height: height, videoBitsPerSecond: Int(Double(profile.videoBitsPerSecond) * pixels),
            audioBitsPerSecond: source.hasAudio ? profile.audioBitsPerSecond : 0)
    }

    public static func options(source: VideoSource, limit: Int64? = nil) -> [ShrinkOption] {
        ShrinkQuality.allCases.map { quality in
            let settings = settings(for: quality, source: source)
            let bytes = settings.estimatedBytes(seconds: source.seconds)
            return ShrinkOption(
                quality: quality, settings: settings, estimatedBytes: bytes,
                bytesPerMinute: settings.estimatedBytes(seconds: 60),
                fits: limit.map { Double(bytes) <= Double($0) * targetShare } ?? true)
        }
    }

    public static func plan(source: VideoSource, quality: ShrinkQuality, limit: Int64? = nil) -> ShrinkPlan {
        var settings = settings(for: quality, source: source)
        if let limit {
            if source.bytes <= limit { return .alreadySmall(bytes: source.bytes) }
            settings = fit(settings, seconds: source.seconds, bytes: Int64(Double(limit) * targetShare))
        } else if source.bytes <= settings.estimatedBytes(seconds: source.seconds) {
            return .alreadySmall(bytes: source.bytes)
        }
        return .encode(settings)
    }

    /// The highest settings at or below `settings` whose estimate stays
    /// within `bytes`: a lower bitrate first, a lower height once the
    /// bitrate drops under what that height needs.
    public static func fit(_ settings: EncodeSettings, seconds: Double, bytes: Int64) -> EncodeSettings {
        var out = settings
        let total = Int(Double(bytes) / 1.01 * 8 / max(seconds, 0.1))
        let video = { min(settings.videoBitsPerSecond, max(total - out.audioBitsPerSecond, 1)) }
        out.videoBitsPerSecond = video()
        while out.videoBitsPerSecond < VideoProfile.floor(height: out.height), let lower = lowerHeight(out.height) {
            out.height = lower
        }
        if out.videoBitsPerSecond < VideoProfile.floor(height: out.height), out.audioBitsPerSecond > 64_000 {
            out.audioBitsPerSecond = 64_000
            out.videoBitsPerSecond = video()
        }
        return out
    }

    static func lowerHeight(_ height: Int) -> Int? {
        [720, 480, 360].first { $0 < height }
    }
}

/// Encodes one file; the real one is `AssetWriterEncoder`, tests use a fake.
public protocol VideoEncoder: Sendable {
    func encode(_ input: URL, to output: URL, settings: EncodeSettings, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Reads what a file is; the real one asks AVFoundation.
public protocol MediaProbing: Sendable {
    func source(of url: URL) async throws -> VideoSource
    /// Whether the file plays: it has a video track and about the duration expected.
    func playable(_ url: URL, seconds: Double?) async -> Bool
}

public struct ShrinkResult: Hashable, Sendable {
    public var output: URL
    public var bytes: Int64
    public var settings: EncodeSettings
    public var attempts: Int
}

/// "Verklein video": encodes, checks the result plays and fits, and with a
/// limit encodes again lower when the encoder overshot. The original stays.
public struct Shrinker: Sendable {
    public let encoder: VideoEncoder
    public let probe: MediaProbing
    public var maxAttempts = 4

    public init(encoder: VideoEncoder, probe: MediaProbing) {
        self.encoder = encoder
        self.probe = probe
    }

    public enum Outcome: Hashable, Sendable {
        case alreadySmall(bytes: Int64)
        case shrunk(ShrinkResult)
    }

    public func shrink(
        _ input: URL, to output: URL, quality: ShrinkQuality, limit: Int64? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Outcome {
        let source = try await probe.source(of: input)
        if case .alreadySmall(let bytes) = ShrinkPlanner.plan(source: source, quality: quality, limit: limit) {
            return .alreadySmall(bytes: bytes)
        }
        return .shrunk(try await encode(input, to: output, quality: quality, limit: limit, source: source, progress: progress))
    }

    /// Encodes until the output plays and, with a limit, fits it.
    public func encode(
        _ input: URL, to output: URL, quality: ShrinkQuality, limit: Int64?, source: VideoSource,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ShrinkResult {
        guard case .encode(var settings) = ShrinkPlanner.plan(source: source, quality: quality, limit: limit) else {
            throw ShrinkError.unreadable
        }
        let fm = FileManager.default
        let temp = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).mp4")
        defer { try? fm.removeItem(at: temp) }
        for attempt in 1...maxAttempts {
            try? fm.removeItem(at: temp)
            try await encoder.encode(input, to: temp, settings: settings, progress: progress)
            guard await probe.playable(temp, seconds: source.seconds) else { throw ShrinkError.unreadable }
            let bytes = (try? fm.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? 0
            if let limit, bytes > limit {
                // Aim the next try as far under the target as this one overshot.
                let target = Double(limit) * ShrinkPlanner.targetShare
                let scaled = Int(Double(settings.videoBitsPerSecond) * target / Double(bytes) * 0.97)
                let next = ShrinkPlanner.fit(
                    EncodeSettings(height: settings.height, videoBitsPerSecond: scaled, audioBitsPerSecond: settings.audioBitsPerSecond),
                    seconds: source.seconds, bytes: Int64(target))
                if next.videoBitsPerSecond < VideoProfile.floor(height: 360) / 2 { break }
                settings = next
                continue
            }
            try? fm.removeItem(at: output)
            try fm.moveItem(at: temp, to: output)
            return ShrinkResult(output: output, bytes: bytes, settings: settings, attempts: attempt)
        }
        throw ShrinkError.doesNotFit(limit: limit ?? 0)
    }
}
