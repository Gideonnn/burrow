import AppKit
import Foundation
import PensieveMedia

/// Keeps a copy of every recording the person can see (their own and shared
/// ones) in iCloud Drive › Pensieve: one folder per recording, all names
/// lowercase, with the shareable video, `audio.m4a`, the summary, the
/// transcript and subtitles; dictations together in `dictaten/`. Labels are
/// Finder tags on the folder. Dobby stays the source of the text and audio;
/// for video the folder is the only home. Folders are never deleted here: a
/// recording removed on the server keeps its copy.
public struct Mirror: Sendable {
    public let root: URL
    let probe: MediaProbing
    /// Whether iCloud has uploaded a file; nil outside iCloud Drive (tests,
    /// another folder), where a verified local copy is enough.
    let isUploaded: @Sendable (URL) -> Bool?

    public init(
        root: URL = Mirror.defaultRoot, probe: MediaProbing = AVProbe(),
        isUploaded: @escaping @Sendable (URL) -> Bool? = Mirror.iCloudUploaded
    ) {
        self.root = root
        self.probe = probe
        self.isUploaded = isUploaded
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Pensieve", isDirectory: true)
    }

    public static let iCloudUploaded: @Sendable (URL) -> Bool? = { url in
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey])
        guard values?.isUbiquitousItem == true else { return nil }
        return values?.ubiquitousItemIsUploaded
    }

    /// What a folder knows about the recording it holds.
    struct Marker: Codable {
        var id: String
        var updatedAt: Date
        var audioBytes: Int?
        /// 2 since the names of Pensieve v2; absent in folders of the first copy.
        var layout: Int?
        var labels: [String]?
    }

    static let markerName = ".pensieve.json"
    static let layout = 2

    /// "2026-10-20_weekstart-noorderlicht".
    public static func folderName(_ recording: RecordingSummary, clash: Bool = false) -> String {
        Naming.folder(title: recording.title, startedAt: recording.startedAt, clash: clash)
    }

    public struct Report: Sendable, Equatable {
        public var written = 0
        /// Videos copied and verified whose originals were deleted.
        public var settled = 0
        /// Videos in their folder still waiting for iCloud before the original goes.
        public var waiting = 0
    }

    /// Brings the copy up to date.
    @discardableResult
    public func sync(_ recordings: [RecordingSummary], api: APIClient, shelf: Shelf? = nil) async throws -> Report {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var known = markers()
        var report = Report()
        let shelved = Dictionary((shelf?.all() ?? []).compactMap { item in item.recordingId.map { ($0, item) } }) { a, _ in a }
        var dictations: [RecordingSummary] = []
        for recording in recordings where recording.audioBytes != nil {
            if recording.kind == .dictation {
                dictations.append(recording)
                continue
            }
            let existing = known[recording.id]
            let video = shelved[recording.id].flatMap { $0.video == nil ? nil : $0 }
            if let existing, existing.marker.updatedAt >= recording.updatedAt, existing.marker.layout == Self.layout,
               (existing.marker.labels ?? []) == recording.labels, video == nil { continue }

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
            Self.migrate(folder)

            let detail = try await api.recording(recording.id)
            if let notes = detail.notesMarkdown {
                try Self.summaryMarkdown(detail, notes: notes)
                    .write(to: folder.appendingPathComponent(Naming.summary), atomically: true, encoding: .utf8)
            }
            if detail.transcript != nil {
                try Self.transcriptMarkdown(detail)
                    .write(to: folder.appendingPathComponent(Naming.transcript), atomically: true, encoding: .utf8)
            }
            if detail.kind.hasVideo, detail.hasSegments, let srt = try? await api.subtitles(detail.id) {
                try srt.write(to: folder.appendingPathComponent(Naming.subtitles), atomically: true, encoding: .utf8)
            }
            let audio = folder.appendingPathComponent(Naming.audio)
            if existing?.marker.audioBytes != recording.audioBytes || !fm.fileExists(atPath: audio.path) {
                try await api.downloadAudio(recording.id, to: audio)
            }
            Self.renameVideo(in: folder, to: Naming.video(title: recording.title))
            if let video, let shelf {
                switch await place(video, in: folder, title: recording.title, shelf: shelf) {
                case .settled: report.settled += 1
                case .waiting: report.waiting += 1
                case .failed: break
                }
            }
            Self.tag(folder, recording.labels)
            try writeMarker(
                Marker(id: recording.id, updatedAt: recording.updatedAt, audioBytes: recording.audioBytes, layout: Self.layout, labels: recording.labels),
                in: folder)
            known[recording.id] = (folder, Marker(id: recording.id, updatedAt: recording.updatedAt, audioBytes: recording.audioBytes, layout: Self.layout, labels: recording.labels))
            report.written += 1
        }
        report.written += try await syncDictations(dictations, api: api)
        return report
    }

    enum Placement { case settled, waiting, failed }

    /// Copies the shelf's MP4 into the folder, checks the copy plays, and
    /// deletes the original only once iCloud has it too.
    func place(_ item: ShelfItem, in folder: URL, title: String, shelf: Shelf) async -> Placement {
        guard let video = item.video else { return .failed }
        let fm = FileManager.default
        let source = shelf.url(video)
        let target = folder.appendingPathComponent(Naming.video(title: title))
        let size = { (url: URL) in (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1 }
        if size(target) != size(source) {
            try? fm.removeItem(at: target)
            do { try fm.copyItem(at: source, to: target) } catch { return .failed }
        }
        guard size(target) == size(source), await probe.playable(target, seconds: nil) else {
            try? fm.removeItem(at: target)
            return .failed
        }
        if isUploaded(target) == false { return .waiting }
        shelf.settle(item)
        return .settled
    }

    // MARK: Files

    /// Renames what the first copy wrote, so nothing is lost or doubled.
    static func migrate(_ folder: URL) {
        let fm = FileManager.default
        for (old, new) in Naming.legacy {
            let from = folder.appendingPathComponent(old)
            guard fm.fileExists(atPath: from.path) else { continue }
            let to = folder.appendingPathComponent(new)
            if fm.fileExists(atPath: to.path) {
                try? fm.removeItem(at: from)
            } else {
                try? fm.moveItem(at: from, to: to)
            }
        }
    }

    static func renameVideo(in folder: URL, to name: String) {
        let fm = FileManager.default
        let target = folder.appendingPathComponent(name)
        guard !fm.fileExists(atPath: target.path) else { return }
        let videos = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mp4" }
        if videos.count == 1, let only = videos.first { try? fm.moveItem(at: only, to: target) }
    }

    static func tag(_ url: URL, _ labels: [String]) {
        try? (url as NSURL).setResourceValue(labels, forKey: .tagNamesKey)
    }

    static func header(_ detail: RecordingDetail) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "nl_NL")
        day.timeZone = .current
        day.dateFormat = "d MMMM yyyy"
        var facts = [day.string(from: detail.startedAt)]
        if let seconds = detail.durationSeconds { facts.append("\(max(1, Int((seconds / 60).rounded()))) min") }
        if !detail.labels.isEmpty { facts.append(detail.labels.joined(separator: ", ")) }
        return "# \(detail.title)\n\n\(facts.joined(separator: " · "))\n\n"
    }

    static func summaryMarkdown(_ detail: RecordingDetail, notes: String) -> String {
        var text = header(detail) + notes.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        if !detail.marks.isEmpty {
            let lines = detail.marks.map { "- \(stamp($0.at))\($0.note.map { " \($0)" } ?? "")" }
            text += "\n## Gemarkeerd\n\n\(lines.joined(separator: "\n"))\n"
        }
        return text
    }

    static func transcriptMarkdown(_ detail: RecordingDetail) -> String {
        guard let segments = detail.segments, !segments.isEmpty else {
            return header(detail) + (detail.transcript ?? "") + "\n"
        }
        let lines = segments.map { s in
            "**\(stamp(s.start))**\(s.speaker.map { " \($0):" } ?? "") \(s.text)"
        }
        return header(detail) + lines.joined(separator: "\n\n") + "\n"
    }

    // MARK: Dictations

    struct DictationEntry: Codable {
        var name: String
        var updatedAt: Date
        var audioBytes: Int?
    }

    /// `dictaten/` with the text and the audio of each, and one index.
    func syncDictations(_ dictations: [RecordingSummary], api: APIClient) async throws -> Int {
        guard !dictations.isEmpty else { return 0 }
        let fm = FileManager.default
        let folder = root.appendingPathComponent(Naming.dictations, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let indexFile = folder.appendingPathComponent(Self.markerName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var index = (try? decoder.decode([String: DictationEntry].self, from: Data(contentsOf: indexFile))) ?? [:]
        var written = 0
        for dictation in dictations where dictation.hasTranscript {
            let name = Naming.dictation(title: dictation.title, startedAt: dictation.startedAt)
            let old = index[dictation.id]
            if let old, old.updatedAt >= dictation.updatedAt, old.name == name { continue }
            if let old, old.name != name {
                for ext in ["md", "m4a"] {
                    try? fm.moveItem(at: folder.appendingPathComponent("\(old.name).\(ext)"), to: folder.appendingPathComponent("\(name).\(ext)"))
                }
            }
            let detail = try await api.recording(dictation.id)
            try "\(detail.transcript ?? "")\n".write(to: folder.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
            let audio = folder.appendingPathComponent("\(name).m4a")
            if old?.audioBytes != dictation.audioBytes || !fm.fileExists(atPath: audio.path) {
                try await api.downloadAudio(dictation.id, to: audio)
            }
            index[dictation.id] = DictationEntry(name: name, updatedAt: dictation.updatedAt, audioBytes: dictation.audioBytes)
            written += 1
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(index).write(to: indexFile, options: .atomic)
        return written
    }

    // MARK: Markers

    func writeMarker(_ marker: Marker, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: folder.appendingPathComponent(Self.markerName), options: .atomic)
    }

    func markers() -> [String: (folder: URL, marker: Marker)] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var out: [String: (URL, Marker)] = [:]
        for folder in folders where folder.lastPathComponent != Naming.dictations {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.markerName)),
                  let marker = try? decoder.decode(Marker.self, from: data)
            else { continue }
            out[marker.id] = (folder, marker)
        }
        return out
    }
}
