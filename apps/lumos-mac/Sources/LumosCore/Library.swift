import Foundation

/// Sizes the way the Bibliotheek writes them: "41,2 GB", "1,2 TB".
public enum Bytes {
    public static func text(_ bytes: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.number.locale(Locale(identifier: "nl_NL")).precision(.fractionLength(0...1))
        if bytes >= 1e12 { return "\((bytes / 1e12).formatted(style.precision(.fractionLength(0...2)))) TB" }
        if bytes >= 1e9 { return "\((bytes / 1e9).formatted(style)) GB" }
        return "\(Int((bytes / 1e6).rounded())) MB"
    }
}

/// "1:12:30" or "48:05".
public enum Clock {
    public static func text(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum ServerDate {
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

/// Seen or not, the way the Bibliotheek shows it. The household watches on
/// one Jellyfin account, so Jellyfin's "played" is "samen gezien"; per
/// person there is only Lumos's own "Al gezien".
public struct Watched: Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case together, partly, none }

    public var kind: Kind
    public var label: String
    /// For sorting: together above partly above none.
    public var rank: Double

    public var symbol: String {
        switch kind {
        case .together: "checkmark.circle.fill"
        case .partly: "circle.lefthalf.filled"
        case .none: "circle"
        }
    }

    public init(server: OnServer?, seen: SeenVerdicts?, mediaType: MediaType) {
        let watched = server?.watched
        if watched?.played == true || seen?.together == true {
            self.init(kind: .together, label: "Samen gezien", rank: 2)
        } else if mediaType == .tv, let done = watched?.episodesPlayed, let total = watched?.episodes, done > 0, total > 0 {
            self.init(kind: .partly, label: "Samen bij \(done) van \(total)", rank: 1 + Double(done) / Double(total))
        } else if let resume = watched?.resume, resume.positionSeconds > 0, mediaType == .movie {
            self.init(kind: .partly, label: resume.minutesLeft.map { "Samen bezig, nog \($0) min" } ?? "Samen bezig", rank: 1.5)
        } else if seen?.me == true {
            self.init(kind: .partly, label: "Jij hebt gezien", rank: 1)
        } else {
            self.init(kind: .none, label: "Niet gezien", rank: 0)
        }
    }

    init(kind: Kind, label: String, rank: Double) {
        self.kind = kind
        self.label = label
        self.rank = rank
    }
}

extension ManageItem {
    public var watched: Watched { Watched(server: server, seen: seen, mediaType: title.mediaType) }
    public var sizeBytes: Double? { server?.sizeBytes }
    public var added: Date? { ServerDate.parse(addedAt) }
    /// Radarr for a film, Sonarr for a series; nobody for a file copied in by hand.
    public var managedBy: String { removable ? (title.mediaType == .movie ? "Radarr" : "Sonarr") : "niemand" }
    public var lockReason: String {
        "Met de hand naar Dobby gekopieerd. \(title.mediaType == .movie ? "Radarr" : "Sonarr") beheert dit bestand niet, dus Lumos kan het niet wissen."
    }
}

/// A line of the Bibliotheek's table, with a value per sortable column.
public struct LibraryRow: Identifiable, Hashable, Sendable {
    public let item: ManageItem
    public var id: TitleRef { item.id }
    public var title: String { item.title.title }
    public var watchedRank: Double { item.watched.rank }
    public var added: Date { item.added ?? .distantPast }
    public var size: Double { item.sizeBytes ?? 0 }

    public init(_ item: ManageItem) { self.item = item }

    public static func == (a: LibraryRow, b: LibraryRow) -> Bool { a.item == b.item }
    public func hash(into hasher: inout Hasher) { hasher.combine(item.id) }
}

/// How the table is sorted; kept per window.
public struct LibrarySort: Equatable, Sendable, RawRepresentable {
    public enum Key: String, Sendable { case title, watched, added, size }

    public var key: Key
    public var ascending: Bool

    public init(key: Key, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "-")
        guard parts.count == 2, let key = Key(rawValue: String(parts[0])) else { return nil }
        self.init(key: key, ascending: parts[1] == "up")
    }

    public var rawValue: String { "\(key.rawValue)-\(ascending ? "up" : "down")" }

    public static let newest = LibrarySort(key: .added, ascending: false)
    public static let largest = LibrarySort(key: .size, ascending: false)

    func sorted(_ rows: [LibraryRow]) -> [LibraryRow] {
        rows.sorted { a, b in
            let order: ComparisonResult =
                switch key {
                case .title: a.title.localizedStandardCompare(b.title)
                case .watched: a.watchedRank == b.watchedRank ? .orderedSame : a.watchedRank < b.watchedRank ? .orderedAscending : .orderedDescending
                case .added: a.added == b.added ? .orderedSame : a.added < b.added ? .orderedAscending : .orderedDescending
                case .size: a.size == b.size ? .orderedSame : a.size < b.size ? .orderedAscending : .orderedDescending
                }
            if order == .orderedSame { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

/// The disk as the Bibliotheek draws it: films, series, other files, what
/// the downloads still need, and what is free.
public struct DiskUse: Equatable, Sendable {
    public var total: Double
    public var films: Double
    public var series: Double
    public var other: Double
    public var coming: Double
    public var free: Double

    /// Under 15 % free the meter in the sidebar turns orange.
    public var tight: Bool { total > 0 && free / total < 0.15 }
    public var used: Double { total - free }

    public init(disk: Disk, library: [ManageItem], busy: [ManageItem]) {
        total = disk.totalBytes
        films = library.filter { $0.title.mediaType == .movie }.compactMap(\.sizeBytes).reduce(0, +)
        series = library.filter { $0.title.mediaType == .tv }.compactMap(\.sizeBytes).reduce(0, +)
        coming = min(disk.freeBytes, busy.compactMap(\.download?.bytesLeft).reduce(0, +))
        other = max(0, disk.totalBytes - disk.freeBytes - films - series)
        free = disk.freeBytes
    }
}

/// What a delete would take, asked before anything is wiped.
public struct DeleteRequest: Identifiable, Sendable {
    public let id = UUID()
    public var items: [ManageItem]
    /// Selected but copied in by hand, so they stay.
    public var kept: Int

    public var bytes: Double { items.compactMap(\.sizeBytes).reduce(0, +) }

    public init(items: [ManageItem], kept: Int) {
        self.items = items
        self.kept = kept
    }

    public var question: String {
        items.count == 1 ? "‘\(items[0].title.title)’ verwijderen van Dobby?" : "\(items.count) titels verwijderen van Dobby?"
    }

    public var message: String {
        var parts = [bytes > 0 ? "De bestanden worden gewist en \(Bytes.text(bytes)) komt vrij." : "De bestanden worden gewist.", "Jullie lijsten blijven staan."]
        if items.contains(where: { $0.title.mediaType == .tv }) { parts.append("Een serie gaat in zijn geheel weg.") }
        if items.contains(where: { $0.server?.watched?.played == true || $0.seen?.together == true || $0.seen?.me == true }) {
            parts.append("Wat jullie gezien hebben, komt bij Al gezien.")
        }
        if kept > 0 { parts.append("\(kept == 1 ? "1 titel blijft" : "\(kept) titels blijven") staan: met de hand gekopieerd.") }
        parts.append("Dit kan niet worden hersteld.")
        return parts.joined(separator: " ")
    }
}
