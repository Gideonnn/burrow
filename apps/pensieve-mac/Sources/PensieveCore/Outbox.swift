import Foundation

/// A finished recording waiting to reach the server. It stays on disk until
/// the server has it, so a recording made on a train survives a closed lid,
/// a crash or a day offline.
public struct PendingUpload: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var audio: String
    // Set once the server knows the upload, so a retry continues it.
    public var uploadId: String?
    public var transcript: String?
    public var notesMarkdown: String?
    public var source: String
    // The folder a RecHoarder import came from, to never import it twice.
    public var importedFrom: String?
    public var lastError: String?

    public init(
        id: String = UUID().uuidString, title: String, startedAt: Date, audio: String, transcript: String? = nil,
        notesMarkdown: String? = nil, source: String = "recorded", importedFrom: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.audio = audio
        self.transcript = transcript
        self.notesMarkdown = notesMarkdown
        self.source = source
        self.importedFrom = importedFrom
    }
}

/// The folder of pending uploads: one audio file and one JSON file each.
public struct Outbox: Sendable {
    public let dir: URL

    public init(dir: URL = Outbox.defaultDir) { self.dir = dir }

    public static var defaultDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pensieve/Outbox", isDirectory: true)
    }

    /// A fresh audio file for a new recording.
    public func newAudioFile() throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(UUID().uuidString).wav")
    }

    public func add(_ upload: PendingUpload) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(upload).write(to: dir.appendingPathComponent("\(upload.id).json"), options: .atomic)
    }

    public func all() -> [PendingUpload] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(PendingUpload.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public func audioURL(_ upload: PendingUpload) -> URL {
        upload.audio.hasPrefix("/") ? URL(fileURLWithPath: upload.audio) : dir.appendingPathComponent(upload.audio)
    }

    /// Forgets an upload the server has; deletes its audio only if the
    /// outbox made it (an imported file stays where it was).
    public func remove(_ upload: PendingUpload) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(upload.id).json"))
        if !upload.audio.hasPrefix("/") { try? FileManager.default.removeItem(at: audioURL(upload)) }
    }

    /// Sends one pending upload to the server and creates the recording.
    public func send(_ upload: PendingUpload, api: APIClient, progress: @Sendable (Double) -> Void = { _ in }) async throws -> RecordingSummary {
        var upload = upload
        do {
            let uploadId = try await api.upload(file: audioURL(upload), resuming: upload.uploadId) { fraction in
                progress(fraction)
            }
            upload.uploadId = uploadId
            try add(upload)
            let recording = try await api.createRecording(.init(
                uploadId: uploadId, title: upload.title, startedAt: upload.startedAt, transcript: upload.transcript,
                notesMarkdown: upload.notesMarkdown, source: upload.source))
            remove(upload)
            return recording
        } catch {
            upload.lastError = error.localizedDescription
            try? add(upload)
            throw error
        }
    }
}
