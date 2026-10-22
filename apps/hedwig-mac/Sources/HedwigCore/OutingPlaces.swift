import Foundation

// Where an outing is: what to ask the map for, the answers kept on disk so a
// page opens with its map at once, and the Dutch travel time line.

public struct OutingPlace: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// The map's own name for the place, used when the outing has no venue.
    public var name: String?
    public var city: String?

    public init(latitude: Double, longitude: Double, name: String? = nil, city: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
        self.city = city
    }
}

public enum PlaceQuery {
    /// "venue, address" first, then the address alone; a venue alone only
    /// when there is no address.
    public static func queries(venue: String?, address: String?) -> [String] {
        let venue = clean(venue), address = clean(address)
        var queries: [String] = []
        switch (venue, address) {
        case let (venue?, address?):
            // "Brabanthallen" with "Brabanthallen 1, Den Bosch" says it once.
            queries.append(address.localizedCaseInsensitiveContains(venue) ? address : "\(venue), \(address)")
            queries.append(address)
        case let (venue?, nil): queries.append(venue)
        case let (nil, address?): queries.append(address)
        case (nil, nil): break
        }
        return queries.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// The same place typed with other spacing or capitals is one entry.
    public static func key(venue: String?, address: String?) -> String? {
        let parts = [clean(venue), clean(address)]
        guard parts.contains(where: { $0 != nil }) else { return nil }
        return parts.map { $0?.lowercased() ?? "" }.joined(separator: "|")
    }

    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.isEmpty ? nil : words
    }
}

extension Outing {
    public var placeKey: String? { PlaceQuery.key(venue: venue, address: address) }
    public var placeQueries: [String] { PlaceQuery.queries(venue: venue, address: address) }

    /// The two lines on the map: the venue and the city, without saying the
    /// same thing twice.
    public func placeLabel(_ place: OutingPlace) -> (title: String, subtitle: String?) {
        let title = PlaceQuery.clean(venue) ?? place.name ?? PlaceQuery.clean(address) ?? ""
        let subtitle = place.city ?? (PlaceQuery.clean(venue) == nil ? nil : PlaceQuery.clean(address))
        guard let subtitle, subtitle.localizedCaseInsensitiveCompare(title) != .orderedSame else { return (title, nil) }
        return (title, subtitle)
    }

    /// A symbol for the pin when the outing has no picture.
    public var kindSymbol: String {
        let kind = (kind ?? "").lowercased()
        let symbols: [(words: [String], symbol: String)] = [
            (["festival"], "tent.fill"),
            (["cabaret", "theater", "theatre", "toneel", "musical", "voorstelling", "comedy"], "theatermasks.fill"),
            (["film", "bioscoop", "cinema"], "film.fill"),
            (["feest", "party", "fuif"], "party.popper.fill"),
            (["sport", "wedstrijd", "voetbal", "hardloop", "marathon"], "figure.run"),
            (["concert", "muziek", "music", "optreden", "dj"], "music.mic"),
        ]
        return symbols.first { $0.words.contains(where: kind.contains) }?.symbol ?? "ticket.fill"
    }
}

// MARK: Apple Maps links

public enum MapsLink {
    /// The place itself, searched near its spot so Maps shows the venue's card.
    public static func place(_ place: OutingPlace, query: String) -> URL {
        link([
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "ll", value: "\(place.latitude),\(place.longitude)"),
        ])
    }

    /// Directions from here, for when the map found nothing.
    public static func route(to query: String) -> URL {
        link([URLQueryItem(name: "daddr", value: query)])
    }

    private static func link(_ items: [URLQueryItem]) -> URL {
        var components = URLComponents(string: "http://maps.apple.com/")!
        components.queryItems = items
        return components.url!
    }
}

// MARK: Travel time

public enum TravelTime {
    /// "ca. 25 min met de auto", "ca. 1 uur en 10 min met de auto". Nil when
    /// it is no trip worth a line: next door, or a drive of half a day.
    public static func text(seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= 90, seconds <= 12 * 3600 else { return nil }
        var minutes = Int((seconds / 60).rounded())
        if minutes >= 10 { minutes = Int((Double(minutes) / 5).rounded()) * 5 }
        let hours = minutes / 60, rest = minutes % 60
        let span =
            switch (hours, rest) {
            case (0, _): "\(rest) min"
            case (_, 0): "\(hours) uur"
            default: "\(hours) uur en \(rest) min"
            }
        return "ca. \(span) met de auto"
    }
}

// MARK: Looking places up

/// What a map search said: a place, nothing there, or no answer at all (no
/// network). Only the last is asked again in the same session.
public enum PlaceSearchResult: Sendable, Equatable {
    case found(OutingPlace)
    case notFound
    case failed
}

/// Finds the place for an outing once and remembers it on disk, keyed by
/// venue and address, so reopening a page needs no search.
@MainActor
public final class PlaceBook {
    public typealias Search = @MainActor (String) async -> PlaceSearchResult

    private let file: URL?
    private let search: Search
    private var places: [String: OutingPlace]
    private var missing: Set<String> = []
    private var running: [String: Task<OutingPlace?, Never>] = [:]
    let limit: Int

    public init(file: URL?, limit: Int = 300, search: @escaping Search) {
        self.file = file
        self.limit = limit
        self.search = search
        places = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: OutingPlace].self, from: $0) } ?? [:]
    }

    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hedwig/places.json")
    }

    public func cached(_ outing: Outing) -> OutingPlace? {
        outing.placeKey.flatMap { places[$0] }
    }

    public func place(for outing: Outing) async -> OutingPlace? {
        guard let key = outing.placeKey else { return nil }
        if let hit = places[key] { return hit }
        if missing.contains(key) { return nil }
        if let task = running[key] { return await task.value }
        let queries = outing.placeQueries
        let task = Task { await self.lookUp(queries, key: key) }
        running[key] = task
        let place = await task.value
        running[key] = nil
        return place
    }

    private func lookUp(_ queries: [String], key: String) async -> OutingPlace? {
        var failed = false
        for query in queries {
            switch await search(query) {
            case let .found(place):
                store(place, for: key)
                return place
            case .notFound: continue
            case .failed: failed = true
            }
        }
        if !failed { missing.insert(key) }
        return nil
    }

    private func store(_ place: OutingPlace, for key: String) {
        places[key] = place
        if places.count > limit, let drop = places.keys.first(where: { $0 != key }) { places[drop] = nil }
        guard let file, let data = try? JSONEncoder().encode(places) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
