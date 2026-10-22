import Foundation

/// Names of folders and files in iCloud Drive › Pensieve: lowercase, no
/// accents, words joined by dashes, so they read the same in Finder, on the
/// iPhone and in a mail attachment.
public enum Naming {
    /// "Interview Femke de Wit" → "interview-femke-de-wit"; "Ideeën" → "ideeen".
    public static func slug(_ title: String, fallback: String = "opname", max: Int = 60) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en"))
            .lowercased()
        let words = folded.unicodeScalars
            .map { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) ? Character($0) : " " }
        let joined = String(words).split(separator: " ").joined(separator: "-")
        guard !joined.isEmpty else { return fallback }
        guard joined.count > max else { return joined }
        let cut = String(joined.prefix(max))
        // Cut at a dash rather than through a word, if one is near.
        if let dash = cut.lastIndex(of: "-"), cut.distance(from: cut.startIndex, to: dash) > max / 2 {
            return String(cut[..<dash])
        }
        return cut
    }

    static func day(_ date: Date, withTime: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = withTime ? "yyyy-MM-dd_HHmm" : "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// "2026-10-22_interview-femke-de-wit", or with the time when two
    /// recordings of a day share a title.
    public static func folder(title: String, startedAt: Date, clash: Bool = false) -> String {
        "\(day(startedAt, withTime: clash))_\(slug(title))"
    }

    /// The video in a recording's folder: "interview-femke-de-wit.mp4".
    public static func video(title: String) -> String { "\(slug(title)).mp4" }

    /// A dictation in `dictaten/`: "2026-10-22_0852_mail-aan-de-aannemer".
    public static func dictation(title: String, startedAt: Date) -> String {
        "\(day(startedAt, withTime: true))_\(slug(title, fallback: "dictaat", max: 40))"
    }

    /// A shrunk copy next to its original: "presentatie-aardrijkskunde-720p.mp4".
    public static func shrunk(original: URL, height: Int) -> String {
        "\(slug(original.deletingPathExtension().lastPathComponent, fallback: "video"))-\(height)p.mp4"
    }

    public static let audio = "audio.m4a"
    public static let summary = "samenvatting.md"
    public static let transcript = "transcript.md"
    public static let subtitles = "ondertitels.srt"
    public static let dictations = "dictaten"
    /// What the first iCloud copy wrote, renamed in place.
    static let legacy = ["notulen.md": summary, "transcript.txt": transcript]
}

/// "07:12", or "1:02:03" past the hour; the server's stamps look the same.
public func stamp(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%02d:%02d", s / 60, s % 60)
}
