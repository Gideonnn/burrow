import Foundation

// The line-up of a festival or concert, read by the server from the
// organiser's own website (packages/contracts/src/outings.ts, outingLineup).

public struct LineupArtist: Codable, Hashable, Sendable {
    public var name: String
    /// "2027-07-02"
    public var day: String?
    public var stage: String?
    /// Local time, "21:30".
    public var startsAt: String?
    public var headliner: Bool

    public init(name: String, day: String? = nil, stage: String? = nil, startsAt: String? = nil, headliner: Bool = false) {
        self.name = name
        self.day = day
        self.stage = stage
        self.startsAt = startsAt
        self.headliner = headliner
    }

    /// "Main Stage · 21:30", or nil when neither is known.
    public var detail: String? {
        let parts = [stage, startsAt].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public struct OutingLineup: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case working, ready, failed

        // A status a newer server adds reads as ready rather than hiding the outing.
        public init(from decoder: Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .ready
        }
    }

    public var status: Status
    public var error: String?
    public var artists: [LineupArtist]
    public var complete: Bool
    public var note: String?
    public var sources: [String]
    public var updatedAt: Date

    public init(
        status: Status, error: String? = nil, artists: [LineupArtist], complete: Bool = false, note: String? = nil,
        sources: [String] = [], updatedAt: Date = .now
    ) {
        self.status = status
        self.error = error
        self.artists = artists
        self.complete = complete
        self.note = note
        self.sources = sources
        self.updatedAt = updatedAt
    }

    /// The first source's host without "www.", as "rockwerchter.be".
    public var sourceHost: String? {
        guard let host = sources.first.flatMap(URL.init(string:))?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public var sourceURL: URL? {
        sources.first.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
    }

    /// Per day in date order, then "Nog geen dag"; headliners first, then by
    /// time, otherwise in the order the website lists them.
    public func days(calendar: Calendar = .current) -> [LineupDay] {
        let grouped = Dictionary(grouping: artists.enumerated()) { $0.element.day.flatMap { Self.date($0, calendar) } == nil ? nil : $0.element.day }
        let keys = grouped.keys.sorted { a, b in
            switch (a, b) {
            case let (a?, b?): a < b
            case (_?, nil): true
            default: false
            }
        }
        return keys.map { key in
            let sorted = grouped[key]!.sorted { a, b in
                if a.element.headliner != b.element.headliner { return a.element.headliner }
                switch (a.element.startsAt, b.element.startsAt) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
            let title = key.flatMap { Self.date($0, calendar) }.map { Self.dayTitle($0, calendar) } ?? "Nog geen dag"
            return LineupDay(day: key, title: title, artists: sorted)
        }
    }

    /// "Donderdag 1 juli"
    public static func dayTitle(_ date: Date, _ calendar: Calendar = .current) -> String {
        let format = DateFormatter()
        format.locale = OutingFormat.locale
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "EEEE d MMMM"
        let text = format.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// "Bijgewerkt 5 minuten geleden", "Bijgewerkt zojuist".
    public func updatedText(now: Date = .now) -> String {
        guard now.timeIntervalSince(updatedAt) >= 60 else { return "Bijgewerkt zojuist" }
        let format = RelativeDateTimeFormatter()
        format.locale = OutingFormat.locale
        format.unitsStyle = .full
        return "Bijgewerkt \(format.localizedString(for: updatedAt, relativeTo: now))"
    }

    static func date(_ day: String, _ calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

public struct LineupDay: Hashable, Sendable, Identifiable {
    public var day: String?
    public var title: String
    public var artists: [LineupArtist]
    public var id: String { day ?? "" }

    public var headliners: [LineupArtist] { artists.filter(\.headliner) }
    public var others: [LineupArtist] { artists.filter { !$0.headliner } }
}

extension Outing {
    /// Festivals and concerts have a line-up worth looking up; any outing
    /// with a website may.
    public var offersLineup: Bool {
        let kind = (kind ?? "").lowercased()
        return ["festival", "concert"].contains(where: kind.contains) || hasWebsite
    }

    public var hasWebsite: Bool { !(url ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
}
