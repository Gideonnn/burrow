@_exported import BurrowKit
import Foundation

// Swift mirrors of packages/contracts/src/pensieve.ts.

public enum RecordingStatus: String, Codable, Sendable {
    case compressing, stored, transcribing, writingNotes = "writing-notes", done, failed
}

public enum RecordingKind: String, Codable, CaseIterable, Sendable {
    case call, video, screen, dictation

    /// Whether the server transcribes it without being asked.
    public var transcribesByDefault: Bool { self == .call || self == .dictation }
    /// Whether the Mac keeps a video file of it.
    public var hasVideo: Bool { self == .video || self == .screen }
}

public struct Mark: Codable, Hashable, Sendable {
    /// Seconds from the start of the recording.
    public var at: Double
    public var note: String?

    public init(at: Double, note: String? = nil) {
        self.at = at
        self.note = note
    }
}

public struct TranscriptSegment: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String?
    public var text: String

    public init(start: Double, end: Double, speaker: String? = nil, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

public struct RecordingLabel: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var count: Int
}

public struct ActionItem: Codable, Hashable, Sendable {
    public var text: String
    public var owner: String?
    public var due: String?
}

public struct Quote: Codable, Hashable, Sendable {
    public var text: String
    public var speaker: String?
    public var at: Double?
}

public struct Chapter: Codable, Hashable, Sendable {
    public var title: String
    public var at: Double?
}

public struct Step: Codable, Hashable, Sendable {
    public var text: String
    public var at: Double?
}

/// The notes of any kind in one shape: `type` says which lists apply
/// (meeting: decisions, actions, open questions; interview: quotes,
/// chapters; steps: steps). The others stay empty.
public struct MeetingNotes: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case meeting, interview, steps }

    public var type: Kind
    public var title: String?
    public var summary: String
    public var decisions: [String]
    public var actions: [ActionItem]
    public var openQuestions: [String]
    public var quotes: [Quote]
    public var chapters: [Chapter]
    public var steps: [Step]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(Kind.self, forKey: .type) ?? .meeting
        title = try c.decodeIfPresent(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actions = try c.decodeIfPresent([ActionItem].self, forKey: .actions) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        quotes = try c.decodeIfPresent([Quote].self, forKey: .quotes) ?? []
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
    }
}

public typealias RecordingNotes = MeetingNotes

public struct RecordingSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: RecordingKind
    public var title: String
    public var owner: Person
    public var mine: Bool
    public var sharedWith: [Person]
    public var labels: [String]
    public var startedAt: Date
    public var durationSeconds: Double?
    public var status: RecordingStatus
    public var error: String?
    public var source: String
    public var audioBytes: Int?
    public var hasTranscript: Bool
    public var hasSegments: Bool
    public var hasNotes: Bool
    public var markCount: Int
    public var preview: String?
    public var updatedAt: Date
}

public struct RecordingDetail: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: RecordingKind
    public var title: String
    public var owner: Person
    public var mine: Bool
    public var sharedWith: [Person]
    public var labels: [String]
    public var startedAt: Date
    public var durationSeconds: Double?
    public var status: RecordingStatus
    public var error: String?
    public var source: String
    public var audioBytes: Int?
    public var hasTranscript: Bool
    public var hasSegments: Bool
    public var hasNotes: Bool
    public var markCount: Int
    public var preview: String?
    public var updatedAt: Date
    public var transcript: String?
    public var segments: [TranscriptSegment]?
    public var marks: [Mark]
    public var notes: MeetingNotes?
    public var notesMarkdown: String?
}

public enum RecordingScope: String, CaseIterable, Sendable {
    case all, mine, shared
}

extension APIClient {
    public func recordings(
        scope: RecordingScope = .all, query: String? = nil, kind: RecordingKind? = nil, labels: [String] = []
    ) async throws -> [RecordingSummary] {
        var items = [URLQueryItem(name: "scope", value: scope.rawValue)]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let kind { items.append(URLQueryItem(name: "kind", value: kind.rawValue)) }
        items += labels.map { URLQueryItem(name: "label", value: $0) }
        return try await call("GET", "api/pensieve/recordings", query: items)
    }

    public func recording(_ id: String) async throws -> RecordingDetail {
        try await call("GET", "api/pensieve/recordings/\(id)")
    }

    public struct NewRecording: Encodable, Sendable {
        public var uploadId: String
        public var kind: String
        public var title: String
        public var startedAt: String
        public var marks: [Mark]
        public var labels: [String]
        public var transcribe: Bool?
        public var transcript: String?
        public var notesMarkdown: String?
        public var source: String

        public init(
            uploadId: String, kind: RecordingKind = .call, title: String, startedAt: Date, marks: [Mark] = [],
            labels: [String] = [], transcribe: Bool? = nil, transcript: String? = nil, notesMarkdown: String? = nil,
            source: String = "recorded"
        ) {
            self.uploadId = uploadId
            self.kind = kind.rawValue
            self.title = title
            self.startedAt = APIClient.isoFractional.string(from: startedAt)
            self.marks = marks
            self.labels = labels
            self.transcribe = transcribe
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

    /// "Maak transcript" for a stored video or screen recording.
    public func requestTranscript(_ id: String) async throws -> RecordingSummary {
        try await call("POST", "api/pensieve/recordings/\(id)/transcribe")
    }

    public func setLabels(recording id: String, _ labels: [String]) async throws -> RecordingSummary {
        try await call("PUT", "api/pensieve/recordings/\(id)/labels", body: ["labels": labels])
    }

    public func setMarks(recording id: String, _ marks: [Mark]) async throws -> RecordingDetail {
        try await call("PUT", "api/pensieve/recordings/\(id)/marks", body: ["marks": marks])
    }

    public func labels() async throws -> [RecordingLabel] {
        try await call("GET", "api/pensieve/labels")
    }

    public func addLabel(_ name: String) async throws -> RecordingLabel {
        try await call("POST", "api/pensieve/labels", body: ["name": name])
    }

    public func renameLabel(_ id: String, to name: String) async throws -> RecordingLabel {
        try await call("PATCH", "api/pensieve/labels/\(id)", body: ["name": name])
    }

    public func deleteLabel(_ id: String) async throws {
        let _: Empty = try await call("DELETE", "api/pensieve/labels/\(id)")
    }

    /// SubRip subtitles made on the server from the segments.
    public func subtitles(_ id: String) async throws -> String {
        let (data, response) = try await session.data(for: request("GET", "api/pensieve/recordings/\(id)/subtitles"))
        try Self.check(response, data)
        return String(decoding: data, as: UTF8.self)
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

    /// Waits until the server has the transcript, for a dictation someone
    /// wants to paste. Polls, as the event stream may not run in a helper.
    public func waitForTranscript(
        _ id: String, timeout: Duration = .seconds(60), every interval: Duration = .milliseconds(400)
    ) async throws -> RecordingDetail {
        let deadline = ContinuousClock.now + timeout
        while true {
            let detail = try await recording(id)
            if detail.transcript != nil { return detail }
            if detail.status == .failed {
                throw APIError.server(status: 500, message: detail.error ?? "het transcriberen mislukte")
            }
            if ContinuousClock.now >= deadline { throw DictationError.timedOut }
            try await Task.sleep(for: interval)
        }
    }
}

public enum DictationError: Error, LocalizedError, Equatable {
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .timedOut: "Het dictaat is nog niet uitgeschreven; het staat straks in Pensieve."
        }
    }
}
