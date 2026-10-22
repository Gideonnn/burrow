import Foundation
import PensieveMedia

/// A video or screen recording's picture, which never goes to the server.
/// The raw original waits here until the shareable MP4 is made and safely in
/// its iCloud folder; only then is it deleted.
public struct ShelfItem: Codable, Hashable, Identifiable, Sendable {
    /// The pending upload of its audio, until the server names it.
    public var id: String
    public var kind: RecordingKind
    public var title: String
    public var startedAt: Date
    /// The raw capture (`.mov`).
    public var original: String
    public var format: RecordingFormat
    /// The compressed MP4, once made.
    public var video: String?
    /// Set once the server has the recording.
    public var recordingId: String?
    public var lastError: String?

    public init(id: String, kind: RecordingKind, title: String, startedAt: Date, original: String, format: RecordingFormat = .normal) {
        self.id = id
        self.kind = kind
        self.title = title
        self.startedAt = startedAt
        self.original = original
        self.format = format
    }
}

public struct Shelf: Sendable {
    public let dir: URL

    public init(dir: URL = Shelf.defaultDir) { self.dir = dir }

    public static var defaultDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pensieve/Video", isDirectory: true)
    }

    /// A fresh file for a raw capture.
    public func newOriginal(extension ext: String = "mov") throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    public func save(_ item: ShelfItem) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(item).write(to: dir.appendingPathComponent("\(item.id).json"), options: .atomic)
    }

    public func all() -> [ShelfItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ShelfItem.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public func item(forRecording id: String) -> ShelfItem? {
        all().first { $0.recordingId == id }
    }

    public func url(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
    }

    /// Ties an item to the recording the server made of its audio.
    public func bind(_ id: String, to recordingId: String) {
        guard var item = all().first(where: { $0.id == id }) else { return }
        item.recordingId = recordingId
        try? save(item)
    }

    /// Makes the MP4 of every item that has none yet; returns the items done.
    @discardableResult
    public func compressPending(encoder: VideoEncoder, probe: MediaProbing) async -> [ShelfItem] {
        var done: [ShelfItem] = []
        for var item in all() where item.video == nil {
            let original = url(item.original)
            let output = dir.appendingPathComponent("\(item.id).mp4")
            do {
                let source = try await probe.source(of: original)
                let wanted = ShrinkPlanner.settings(for: item.format.profile, source: source)
                try await encoder.encode(original, to: output, settings: wanted, progress: { _ in })
                guard await probe.playable(output, seconds: source.seconds) else { throw ShrinkError.unreadable }
                item.video = output.lastPathComponent
                item.lastError = nil
                done.append(item)
            } catch {
                try? FileManager.default.removeItem(at: output)
                item.lastError = error.localizedDescription
            }
            try? save(item)
        }
        return done
    }

    /// The MP4 is in iCloud and plays: the original and the shelf's copy go.
    public func settle(_ item: ShelfItem) {
        let fm = FileManager.default
        try? fm.removeItem(at: url(item.original))
        if let video = item.video { try? fm.removeItem(at: url(video)) }
        try? fm.removeItem(at: dir.appendingPathComponent("\(item.id).json"))
    }
}
