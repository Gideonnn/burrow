import Foundation

/// Finds the meetings RecHoarder kept in iCloud Drive › Meetings, so Pensieve
/// can upload them once with the transcripts and notes they already have.
/// RecHoarder's folders are `yyyy-MM-dd_name`, or `yyyy-MM-dd_name_HHmm` for a
/// second one on the same day, each with `<folder>.wav` and maybe `.txt` and
/// `.md` next to it.
public struct RecHoarderImport: Sendable {
    public let root: URL

    public init(root: URL = RecHoarderImport.defaultRoot) { self.root = root }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Meetings", isDirectory: true)
    }

    public struct Scan: Sendable {
        public var ready: [PendingUpload]
        // Folders whose audio is still only in iCloud; asked to download.
        public var downloading: [String]
    }

    /// Meetings not imported before. Audio that iCloud has not downloaded
    /// yet is requested and left for a next scan.
    public func scan(skipping done: Set<String>) -> Scan {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var ready: [PendingUpload] = []
        var downloading: [String] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let slug = folder.lastPathComponent
            guard !done.contains(slug), let (title, day) = Self.parse(slug) else { continue }
            let wav = folder.appendingPathComponent("\(slug).wav")
            if !fm.fileExists(atPath: wav.path) {
                let placeholder = folder.appendingPathComponent(".\(slug).wav.icloud")
                if fm.fileExists(atPath: placeholder.path) {
                    try? fm.startDownloadingUbiquitousItem(at: wav)
                    downloading.append(slug)
                }
                continue
            }
            var started = day
            if let created = try? wav.resourceValues(forKeys: [.creationDateKey]).creationDate,
               Calendar.current.isDate(created, inSameDayAs: day) {
                started = created
            }
            let read = { (ext: String) in
                (try? String(contentsOf: folder.appendingPathComponent("\(slug).\(ext)"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            ready.append(PendingUpload(
                title: title, startedAt: started, audio: wav.path, transcript: read("txt").flatMap { $0.isEmpty ? nil : $0 },
                notesMarkdown: read("md").flatMap { $0.isEmpty ? nil : $0 }, source: "imported", importedFrom: slug))
        }
        return Scan(ready: ready, downloading: downloading)
    }

    /// "2026-08-19_standup_1902" → ("standup", 19 August 2026).
    static func parse(_ slug: String) -> (String, Date)? {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = .current
        guard slug.count > 11, let date = day.date(from: String(slug.prefix(10))),
              slug[slug.index(slug.startIndex, offsetBy: 10)] == "_"
        else { return nil }
        var parts = slug.dropFirst(11).split(separator: "_").map(String.init)
        if parts.count > 1, let last = parts.last, last.count == 4, Int(last) != nil { parts.removeLast() }
        let name = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : (name, date)
    }
}
