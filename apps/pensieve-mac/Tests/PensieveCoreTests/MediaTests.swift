import Foundation
import PensieveMedia
import Testing
@testable import PensieveCore

private let MB: Int64 = 1_000_000

@Suite struct NamingTests {
    @Test func namesAreLowercaseWithoutAccentsOrPunctuation() {
        #expect(Naming.slug("Interview Femke de Wit") == "interview-femke-de-wit")
        #expect(Naming.slug("Ideeën: boekenkast op zolder!") == "ideeen-boekenkast-op-zolder")
        #expect(Naming.slug("Teams-overleg Studio Vos") == "teams-overleg-studio-vos")
        #expect(Naming.slug("  ?? ") == "opname")
        #expect(Naming.slug("Café & crème brûlée") == "cafe-creme-brulee")
    }

    @Test func longTitlesAreCutBetweenWords() {
        let slug = Naming.slug("Een heel lang overleg over de planning van de lancering in november en december")
        #expect(slug.count <= 60)
        #expect(!slug.hasSuffix("-"))
        #expect(slug.hasPrefix("een-heel-lang-overleg"))
    }

    @Test func filesAndFoldersFollowTheDesign() {
        let date = ISO8601DateFormatter().date(from: "2026-10-22T08:52:00Z")!
        let local = Naming.day(date, withTime: false)
        #expect(Naming.folder(title: "Interview Femke de Wit", startedAt: date) == "\(local)_interview-femke-de-wit")
        #expect(Naming.video(title: "Interview Femke de Wit") == "interview-femke-de-wit.mp4")
        #expect(Naming.dictation(title: "Mail aan de aannemer", startedAt: date).hasSuffix("_mail-aan-de-aannemer"))
        #expect(Naming.shrunk(original: URL(fileURLWithPath: "/tmp/Presentatie Aardrijkskunde.MOV"), height: 720) == "presentatie-aardrijkskunde-720p.mp4")
    }
}

@Suite struct EstimateTests {
    // 6:24 of 4K from an iPhone, 1.2 GB, as in the design.
    let iphone = VideoSource(seconds: 384, width: 3840, height: 2160, bytes: 1_200 * MB)

    @Test func qualitiesEstimateTheSizesOfTheDesign() {
        let options = ShrinkPlanner.options(source: iphone)
        #expect(options.map(\.quality) == [.high, .normal, .small])
        let megabytes: [Int] = options.map { Int(($0.estimatedBytes + MB / 2) / MB) }
        #expect(megabytes == [89, 44, 22])
        let perMinute: [Double] = options.map { (Double($0.bytesPerMinute) / 100_000).rounded() / 10 }
        #expect(perMinute == [13.9, 6.9, 3.4])
        #expect(options.map(\.settings.height) == [1080, 720, 480])
    }

    @Test func aLimitMarksTheQualitiesThatDoNotFit() {
        let options = ShrinkPlanner.options(source: iphone, limit: 50 * MB)
        #expect(options.map(\.fits) == [false, true, true])
    }

    @Test func neverUpscales() {
        let small = VideoSource(seconds: 60, width: 1280, height: 720, bytes: 200 * MB)
        let high = ShrinkPlanner.settings(for: .high, source: small)
        #expect(high.height == 720)
        #expect(high.videoBitsPerSecond <= VideoProfile.p720.videoBitsPerSecond)
        let portrait = EncodeSettings(VideoProfile.p720).dimensions(sourceWidth: 1080, sourceHeight: 1920)
        #expect(portrait.width == 720 && portrait.height == 1280)
        let tiny = EncodeSettings(VideoProfile.p1080).dimensions(sourceWidth: 640, sourceHeight: 360)
        #expect(tiny.width == 640 && tiny.height == 360)
    }

    @Test func saysSoWhenTheSourceIsAlreadySmallEnough() {
        let small = VideoSource(seconds: 60, width: 1280, height: 720, bytes: 5 * MB)
        #expect(ShrinkPlanner.plan(source: small, quality: .normal) == .alreadySmall(bytes: 5 * MB))
        #expect(ShrinkPlanner.plan(source: small, quality: .small, limit: 25 * MB) == .alreadySmall(bytes: 5 * MB))
    }

    @Test func aLimitAimsAtNinetyFivePercentAndDropsTheHeightWhenTheBitrateGetsTooLow() {
        guard case .encode(let normal) = ShrinkPlanner.plan(source: iphone, quality: .normal, limit: 25 * MB) else {
            Issue.record("expected an encode")
            return
        }
        #expect(normal.estimatedBytes(seconds: iphone.seconds) <= Int64(Double(25 * MB) * 0.95))
        #expect(normal.height == 720)

        guard case .encode(let tight) = ShrinkPlanner.plan(source: iphone, quality: .normal, limit: 10 * MB) else {
            Issue.record("expected an encode")
            return
        }
        #expect(tight.estimatedBytes(seconds: iphone.seconds) <= Int64(Double(10 * MB) * 0.95))
        #expect(tight.height < 720)
        #expect(tight.audioBitsPerSecond == 64_000)

        guard case .encode(let high) = ShrinkPlanner.plan(source: iphone, quality: .high, limit: 100 * MB) else {
            Issue.record("expected an encode")
            return
        }
        #expect(high.height == 1080)
        #expect(high.estimatedBytes(seconds: iphone.seconds) <= 95 * MB)
    }

    @Test func recordingFormatsMatchTheSettings() {
        #expect(RecordingFormat.small.profile.height == 720)
        #expect(RecordingFormat.normal.profile.height == 1080)
        #expect(RecordingFormat.normal.profile.bytesPerMinute < 15 * MB)
        #expect(RecordingFormat.high.profile.bitsPerSecond > RecordingFormat.normal.profile.bitsPerSecond)
    }
}

/// An encoder that writes as many bytes as the settings would make, times
/// an overshoot per attempt, and remembers what it was asked.
final class FakeEncoder: VideoEncoder, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [EncodeSettings] = []
    let seconds: Double
    let overshoot: [Double]

    init(seconds: Double, overshoot: [Double] = [1]) {
        self.seconds = seconds
        self.overshoot = overshoot
    }

    func encode(_ input: URL, to output: URL, settings: EncodeSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        let attempt = lock.withLock { calls.append(settings); return calls.count - 1 }
        let factor = overshoot[min(attempt, overshoot.count - 1)]
        let bytes = Int(Double(settings.estimatedBytes(seconds: seconds)) * factor)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        progress(1)
    }
}

struct FakeProbe: MediaProbing {
    var source: VideoSource
    var plays = true

    func source(of url: URL) async throws -> VideoSource {
        var found = source
        if let bytes = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64, bytes > 0 { found.bytes = bytes }
        return found
    }

    func playable(_ url: URL, seconds: Double?) async -> Bool { plays && FileManager.default.fileExists(atPath: url.path) }
}

@Suite struct ShrinkTests {
    func original(bytes: Int64) throws -> URL {
        let file = temporaryDirectory().appendingPathComponent("Presentatie aardrijkskunde.mov")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return file
    }

    @Test func encodesAgainLowerWhenTheFirstTryOvershootsTheLimit() async throws {
        let source = try original(bytes: 1_200 * MB)
        let encoder = FakeEncoder(seconds: 384, overshoot: [1.2, 1.0])
        let shrinker = Shrinker(encoder: encoder, probe: FakeProbe(source: VideoSource(seconds: 384, width: 3840, height: 2160, bytes: 0)))
        let output = source.deletingLastPathComponent().appendingPathComponent(Naming.shrunk(original: source, height: 720))
        let outcome = try await shrinker.shrink(source, to: output, quality: .normal, limit: 50 * MB)

        guard case .shrunk(let result) = outcome else {
            Issue.record("expected a shrunk file")
            return
        }
        #expect(result.attempts == 2)
        #expect(result.bytes <= 50 * MB)
        #expect(encoder.calls[1].videoBitsPerSecond < encoder.calls[0].videoBitsPerSecond)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path)
        #expect(leftovers.sorted() == ["Presentatie aardrijkskunde.mov", "presentatie-aardrijkskunde-720p.mp4"])
    }

    @Test func givesUpWhenNothingFitsAndLeavesNoFileBehind() async throws {
        let source = try original(bytes: 1_200 * MB)
        let encoder = FakeEncoder(seconds: 384, overshoot: [10])
        let shrinker = Shrinker(encoder: encoder, probe: FakeProbe(source: VideoSource(seconds: 384, width: 3840, height: 2160, bytes: 0)))
        let output = source.deletingLastPathComponent().appendingPathComponent("uit.mp4")
        await #expect(throws: ShrinkError.doesNotFit(limit: 25 * MB)) {
            _ = try await shrinker.shrink(source, to: output, quality: .small, limit: 25 * MB)
        }
        #expect(!encoder.calls.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path) == ["Presentatie aardrijkskunde.mov"])
    }

    @Test func refusesAnOutputThatDoesNotPlay() async throws {
        let source = try original(bytes: 1_200 * MB)
        let shrinker = Shrinker(
            encoder: FakeEncoder(seconds: 384),
            probe: FakeProbe(source: VideoSource(seconds: 384, width: 3840, height: 2160, bytes: 0), plays: false))
        await #expect(throws: ShrinkError.unreadable) {
            _ = try await shrinker.shrink(source, to: source.deletingLastPathComponent().appendingPathComponent("uit.mp4"), quality: .normal)
        }
    }

    @Test func doesNothingWithAVideoThatAlreadyFits() async throws {
        let source = try original(bytes: 20 * MB)
        let encoder = FakeEncoder(seconds: 384)
        let shrinker = Shrinker(encoder: encoder, probe: FakeProbe(source: VideoSource(seconds: 384, width: 1920, height: 1080, bytes: 0)))
        let outcome = try await shrinker.shrink(source, to: source.appendingPathExtension("mp4"), quality: .normal, limit: 25 * MB)
        #expect(outcome == .alreadySmall(bytes: 20 * MB))
        #expect(encoder.calls.isEmpty)
    }
}

private let hasFfmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].contains { FileManager.default.isExecutableFile(atPath: $0) }

/// The real encoder on a real file, made by ffmpeg when it is installed.
@Suite(.enabled(if: hasFfmpeg)) struct AVFoundationTests {
    func sample(seconds: Int = 3) throws -> URL {
        let dir = temporaryDirectory()
        let file = dir.appendingPathComponent("bron.mov")
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }!)
        ffmpeg.arguments = [
            "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=25:duration=\(seconds)",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)", "-c:v", "h264_videotoolbox", "-b:v", "8M",
            "-c:a", "aac", "-shortest", file.path,
        ]
        try ffmpeg.run()
        ffmpeg.waitUntilExit()
        return file
    }

    @Test func encodesAPlayableSmallerMP4AndExtractsTheSound() async throws {
        let input = try sample()
        let output = input.deletingLastPathComponent().appendingPathComponent("klein.mp4")
        try await AssetWriterEncoder().encode(input, to: output, settings: EncodeSettings(VideoProfile.p480), progress: { _ in })
        let probe = AVProbe()
        let made = try await probe.source(of: output)
        #expect(made.shortSide == 480)
        #expect(made.width == 854)
        #expect(made.hasAudio)
        #expect(await probe.playable(output, seconds: 3))
        #expect(made.bytes < (try await probe.source(of: input)).bytes)

        let audio = input.deletingLastPathComponent().appendingPathComponent("audio.m4a")
        try await AudioExtractor.extract(from: input, to: audio)
        let sound = try await probe.source(of: audio)
        #expect(abs(sound.seconds - 3) < 0.2)
        #expect(sound.hasAudio)
    }
}
