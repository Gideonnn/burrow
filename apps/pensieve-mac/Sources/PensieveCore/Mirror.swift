import Foundation

/// Keeps a copy of every finished recording the person can see (their own and
/// shared ones) in iCloud Drive › Pensieve, one dated folder each with the
/// audio, the transcript and the notes. Dobby stays the source; the copy is
/// for Finder, Spotlight, the iPhone, and as a second backup. Folders are
/// never deleted here: a recording removed on the server keeps its copy.
public struct Mirror: Sendable {
    public let root: URL

    public init(root: URL = Mirror.defaultRoot) { self.root = root }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Pensieve", isDirectory: true)
    }

    /// What a folder knows about the recording it holds.
    struct Marker: Codable {
        var id: String
        var updatedAt: Date
        var audioBytes: Int?
    }

    static let markerName = ".pensieve.json"

    /// "2026-10-20_weekstart-noorderlicht".
    public static func folderName(_ recording: RecordingSummary, clash: Bool = false) -> String {
        let day = DateFormatter()
        day.dateFormat = clash ? "yyyy-MM-dd_HHmm" : "yyyy-MM-dd"
        day.timeZone = .current
        let slug = recording.title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "\(day.string(from: recording.startedAt))_\(slug.isEmpty ? "opname" : String(slug.prefix(60)))"
    }

    /// Brings the copy up to date; returns how many folders were written.
    @discardableResult
    public func sync(_ recordings: [RecordingSummary], api: APIClient) async throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var known = markers()
        var written = 0
        for recording in recordings where recording.status == .done {
            let existing = known[recording.id]
            if let existing, existing.marker.updatedAt >= recording.updatedAt { continue }
            var folder = existing?.folder ?? root.appendingPathComponent(Self.folderName(recording))
            // A renamed recording moves its folder along.
            let wanted = root.appendingPathComponent(Self.folderName(recording))
            if folder != wanted, !fm.fileExists(atPath: wanted.path) {
                try? fm.moveItem(at: folder, to: wanted)
                if fm.fileExists(atPath: wanted.path) { folder = wanted }
            }
            if existing == nil, fm.fileExists(atPath: folder.path) {
                folder = root.appendingPathComponent(Self.folderName(recording, clash: true))
            }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)

            let detail = try await api.recording(recording.id)
            if let notes = detail.notesMarkdown {
                try "# \(detail.title)\n\n\(notes)".write(to: folder.appendingPathComponent("notulen.md"), atomically: true, encoding: .utf8)
            }
            if let transcript = detail.transcript {
                try transcript.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            }
            let audio = folder.appendingPathComponent("audio.m4a")
            if existing?.marker.audioBytes != recording.audioBytes || !fm.fileExists(atPath: audio.path) {
                try await api.downloadAudio(recording.id, to: audio)
            }
            let marker = Marker(id: recording.id, updatedAt: recording.updatedAt, audioBytes: recording.audioBytes)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(marker).write(to: folder.appendingPathComponent(Self.markerName), options: .atomic)
            known[recording.id] = (folder, marker)
            written += 1
        }
        return written
    }

    func markers() -> [String: (folder: URL, marker: Marker)] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var out: [String: (URL, Marker)] = [:]
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.markerName)),
                  let marker = try? decoder.decode(Marker.self, from: data)
            else { continue }
            out[marker.id] = (folder, marker)
        }
        return out
    }
}
