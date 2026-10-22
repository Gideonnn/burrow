import Foundation

/// What a shareable H.264 MP4 is encoded at. Bitrates give the sizes the
/// design promises: 13.8, 6.9 and 3.4 MB a minute for 1080p, 720p and 480p.
public struct VideoProfile: Hashable, Sendable {
    /// The short side: 1080 for 1920×1080, and for a portrait 1080×1920.
    public var height: Int
    public var videoBitsPerSecond: Int
    public var audioBitsPerSecond: Int

    public init(height: Int, videoBitsPerSecond: Int, audioBitsPerSecond: Int) {
        self.height = height
        self.videoBitsPerSecond = videoBitsPerSecond
        self.audioBitsPerSecond = audioBitsPerSecond
    }

    public static let p480 = VideoProfile(height: 480, videoBitsPerSecond: 390_000, audioBitsPerSecond: 64_000)
    public static let p720 = VideoProfile(height: 720, videoBitsPerSecond: 820_000, audioBitsPerSecond: 96_000)
    public static let p1080 = VideoProfile(height: 1080, videoBitsPerSecond: 1_744_000, audioBitsPerSecond: 96_000)
    public static let p1080High = VideoProfile(height: 1080, videoBitsPerSecond: 3_904_000, audioBitsPerSecond: 96_000)

    public var bitsPerSecond: Int { videoBitsPerSecond + audioBitsPerSecond }

    /// Bytes for this long, plus a percent for the MP4's own bookkeeping.
    public func estimatedBytes(seconds: Double) -> Int64 {
        Int64(Double(bitsPerSecond) / 8 * seconds * 1.01)
    }

    public var bytesPerMinute: Int64 { estimatedBytes(seconds: 60) }

    /// The least video bitrate still worth watching at this height; below it
    /// a lower height looks better.
    public static func floor(height: Int) -> Int {
        switch height {
        case ...480: 120_000
        case ...720: 300_000
        default: 600_000
        }
    }
}

/// The format a new video or screen recording is kept in (Settings ›
/// Bestanden › Formaat van video).
public enum RecordingFormat: String, CaseIterable, Codable, Sendable {
    case small, normal, high

    public var profile: VideoProfile {
        switch self {
        case .small: .p720
        case .normal: .p1080
        case .high: .p1080High
        }
    }
}

/// The three choices of "Verklein video".
public enum ShrinkQuality: String, CaseIterable, Codable, Sendable {
    case high, normal, small

    public var profile: VideoProfile {
        switch self {
        case .high: .p1080
        case .normal: .p720
        case .small: .p480
        }
    }

    /// The next quality down, for a size limit the first choice overshoots.
    public var lower: ShrinkQuality? {
        switch self {
        case .high: .normal
        case .normal: .small
        case .small: nil
        }
    }
}

/// What the encoder is asked for.
public struct EncodeSettings: Hashable, Sendable {
    /// Short side of the output; the long side follows the source's aspect.
    public var height: Int
    public var videoBitsPerSecond: Int
    public var audioBitsPerSecond: Int

    public init(height: Int, videoBitsPerSecond: Int, audioBitsPerSecond: Int) {
        self.height = height
        self.videoBitsPerSecond = videoBitsPerSecond
        self.audioBitsPerSecond = audioBitsPerSecond
    }

    public init(_ profile: VideoProfile) {
        self.init(height: profile.height, videoBitsPerSecond: profile.videoBitsPerSecond, audioBitsPerSecond: profile.audioBitsPerSecond)
    }

    public func estimatedBytes(seconds: Double) -> Int64 {
        Int64(Double(videoBitsPerSecond + audioBitsPerSecond) / 8 * seconds * 1.01)
    }

    /// Output dimensions for a source of `width`×`height` (natural, before
    /// rotation): never larger than the source, both sides even.
    public func dimensions(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let short = min(sourceWidth, sourceHeight)
        guard short > 0 else { return (0, 0) }
        let scale = min(1, Double(height) / Double(short))
        let even = { (n: Double) in max(2, Int((n / 2).rounded()) * 2) }
        return (even(Double(sourceWidth) * scale), even(Double(sourceHeight) * scale))
    }
}

/// A video file as found on disk.
public struct VideoSource: Hashable, Sendable {
    public var seconds: Double
    /// Natural size, before the rotation a phone stores beside it.
    public var width: Int
    public var height: Int
    public var bytes: Int64
    public var hasAudio: Bool

    public init(seconds: Double, width: Int, height: Int, bytes: Int64, hasAudio: Bool = true) {
        self.seconds = seconds
        self.width = width
        self.height = height
        self.bytes = bytes
        self.hasAudio = hasAudio
    }

    public var shortSide: Int { min(width, height) }
}
