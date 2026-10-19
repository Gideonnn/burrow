@_exported import BurrowKit
import Foundation

// Swift mirrors of packages/contracts/src/pensieve.ts.

public enum RecordingStatus: String, Codable, Sendable {
    case compressing, transcribing, writingNotes = "writing-notes", done, failed
}

public struct ActionItem: Codable, Hashable, Sendable {
    public var text: String
    public var owner: String?
    public var due: String?
}

public struct MeetingNotes: Codable, Hashable, Sendable {
    public var title: String?
    public var summary: String
    public var decisions: [String]
    public var actions: [ActionItem]
    public var openQuestions: [String]
}

public struct RecordingSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var owner: Person
    public var mine: Bool
    public var sharedWith: [Person]
    public var startedAt: Date
    public var durationSeconds: Double?
    public var status: RecordingStatus
    public var error: String?
    public var source: String
    public var audioBytes: Int?
    public var hasTranscript: Bool
    public var hasNotes: Bool
    public var preview: String?
    public var updatedAt: Date
}

public struct RecordingDetail: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var owner: Person
    public var mine: Bool
    public var sharedWith: [Person]
    public var startedAt: Date
    public var durationSeconds: Double?
    public var status: RecordingStatus
    public var error: String?
    public var source: String
    public var audioBytes: Int?
    public var hasTranscript: Bool
    public var hasNotes: Bool
    public var preview: String?
    public var updatedAt: Date
    public var transcript: String?
    public var notes: MeetingNotes?
    public var notesMarkdown: String?
}

public enum RecordingScope: String, CaseIterable, Sendable {
    case all, mine, shared
}

extension APIClient {
    public func recordings(scope: RecordingScope = .all, query: String? = nil) async throws -> [RecordingSummary] {
        var items = [URLQueryItem(name: "scope", value: scope.rawValue)]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        return try await call("GET", "api/pensieve/recordings", query: items)
    }

    public func recording(_ id: String) async throws -> RecordingDetail {
        try await call("GET", "api/pensieve/recordings/\(id)")
    }

    public struct NewRecording: Encodable, Sendable {
        public var uploadId: String
        public var title: String
        public var startedAt: String
        public var transcript: String?
        public var notesMarkdown: String?
        public var source: String

        public init(uploadId: String, title: String, startedAt: Date, transcript: String? = nil, notesMarkdown: String? = nil, source: String = "recorded") {
            self.uploadId = uploadId
            self.title = title
            self.startedAt = APIClient.isoFractional.string(from: startedAt)
            self.transcript = transcript
            self.notesMarkdown = notesMarkdown
            self.source = source
        }
    }

    public func createRecording(_ recording: NewRecording) async throws -> RecordingSummary {
        try await call("POST", "api/pensieve/recordings", body: recording)
    }

    public func renameRecording(_ id: String, title: String) async throws -> RecordingSummary {
        try await call("PATCH", "api/pensieve/recordings/\(id)", body: ["title": title])
    }

    public func deleteRecording(_ id: String) async throws {
        let _: Empty = try await call("DELETE", "api/pensieve/recordings/\(id)")
    }

    public func share(recording id: String, with personId: String) async throws -> RecordingSummary {
        try await call("POST", "api/pensieve/recordings/\(id)/share", body: ["personId": personId])
    }

    public func unshare(recording id: String, from personId: String) async throws -> RecordingSummary {
        try await call("DELETE", "api/pensieve/recordings/\(id)/share/\(personId)")
    }

    public func redo(recording id: String, step: String) async throws -> RecordingSummary {
        try await call("POST", "api/pensieve/recordings/\(id)/redo", body: ["step": step])
    }

    /// Where the audio streams from, for a player that sends the key itself.
    public func audioRequest(_ id: String) -> URLRequest {
        request("GET", "api/pensieve/recordings/\(id)/audio")
    }

    public func downloadAudio(_ id: String, to file: URL) async throws {
        let (temp, response) = try await session.download(for: audioRequest(id))
        try Self.check(response, Data())
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temp, to: file)
    }
}
