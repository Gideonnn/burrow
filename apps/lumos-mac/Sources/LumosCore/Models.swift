@_exported import BurrowKit
import Foundation

// Mirrors of packages/contracts/src/lumos.ts.

public enum MediaType: String, Codable, Sendable, Hashable {
    case movie, tv
}

public enum DataOrigin: String, Codable, Sendable {
    case live, fixture
}

public enum ListScope: String, Codable, Sendable, CaseIterable {
    case shared, mine
}

public enum Availability: String, Codable, Sendable {
    case notRequested = "not-requested"
    case requested
    case waitingForRelease = "waiting-for-release"
    case downloading
    case importing
    case importProblem = "import-problem"
    case available
    case partiallyAvailable = "partially-available"

    public var label: String {
        switch self {
        case .notRequested: "Nog niet in Jellyfin"
        case .requested: "Aangevraagd"
        case .waitingForRelease: "Wacht op release"
        case .downloading: "Wordt gedownload"
        case .importing: "Wordt toegevoegd"
        case .importProblem: "Probleem bij toevoegen"
        case .available: "In Jellyfin"
        case .partiallyAvailable: "Deels in Jellyfin"
        }
    }
}

public enum VerdictKind: String, Codable, Sendable {
    case notNow = "not-now"
    case seen
    case moreLikeThis = "more-like-this"
    case lessLikeThis = "less-like-this"

    public var isPass: Bool { self == .notNow || self == .seen }
}

public struct TitleRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public var mediaType: MediaType
    public var tmdbId: Int

    public init(mediaType: MediaType, tmdbId: Int) {
        self.mediaType = mediaType
        self.tmdbId = tmdbId
    }

    public var description: String { "\(mediaType.rawValue):\(tmdbId)" }

    public init?(_ text: String) {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let type = MediaType(rawValue: String(parts[0])), let id = Int(parts[1]) else { return nil }
        self.init(mediaType: type, tmdbId: id)
    }
}

public struct VerdictRef: Codable, Sendable, Hashable {
    public var id: String
    public var kind: VerdictKind
    public var reason: String?
}

public struct TitleSummary: Codable, Sendable, Hashable, Identifiable {
    public var mediaType: MediaType
    public var tmdbId: Int
    public var title: String
    public var year: Int?
    public var runtimeMinutes: Int?
    public var seasons: Int?
    public var genres: [String]
    public var traits: [String]
    public var language: String?
    public var poster: String?
    public var backdrop: String?
    public var availability: Availability
    public var hasTrailer: Bool
    public var onList: Bool
    public var onShared: Bool
    public var onMine: Bool
    public var pass: VerdictRef?
    public var taste: VerdictRef?
    public var match: String?

    public var ref: TitleRef { TitleRef(mediaType: mediaType, tmdbId: tmdbId) }
    public var id: TitleRef { ref }

    public var kind: String { mediaType == .tv ? "Serie" : "Film" }

    /// "1 u 30 min" or "2 seizoenen": shown, never filtered on.
    public var length: String? {
        if mediaType == .tv, let seasons { return seasons == 1 ? "1 seizoen" : "\(seasons) seizoenen" }
        guard let minutes = runtimeMinutes else { return nil }
        let hours = minutes / 60
        return hours > 0 ? "\(hours) u \(minutes % 60) min" : "\(minutes) min"
    }

    public var line: String {
        [year.map(String.init), length, genres.first].compactMap { $0 }.joined(separator: " · ")
    }
}

public struct Score: Codable, Sendable, Hashable {
    public var source: String
    public var label: String?
    public var value: Double
    public var scale: String
    public var votes: Int?
    public var votesAtLeast: Bool
    public var asOf: String
    public var url: String?

    public var valueText: String {
        scale == "percent" ? "\(Int(value))%" : "\(value.formatted(.number.precision(.fractionLength(1)))) / 10"
    }

    public var votesText: String? {
        guard let votes else { return nil }
        let unit = scale == "percent" && label == "Critics" ? "recensies" : "stemmen"
        return "\(votes.formatted())\(votesAtLeast ? "+" : "") \(unit)"
    }
}

public struct Snippet: Codable, Sendable, Hashable {
    public var source: String
    public var author: String?
    public var url: String
    public var quote: String
    public var language: String
    public var checkedAt: String
}

public enum Trailer: Codable, Sendable, Hashable {
    case youtube(key: String, url: String, publisher: String, language: String?, checkedAt: String)
    case direct(url: String, sourceUrl: String?, publisher: String, language: String?, license: String?, checkedAt: String)

    private enum CodingKeys: String, CodingKey {
        case provider, key, url, sourceUrl, publisher, language, license, checkedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let publisher = try c.decode(String.self, forKey: .publisher)
        let language = try c.decodeIfPresent(String.self, forKey: .language)
        let checkedAt = try c.decode(String.self, forKey: .checkedAt)
        switch try c.decode(String.self, forKey: .provider) {
        case "youtube":
            self = .youtube(
                key: try c.decode(String.self, forKey: .key), url: try c.decode(String.self, forKey: .url),
                publisher: publisher, language: language, checkedAt: checkedAt)
        default:
            self = .direct(
                url: try c.decode(String.self, forKey: .url), sourceUrl: try c.decodeIfPresent(String.self, forKey: .sourceUrl),
                publisher: publisher, language: language, license: try c.decodeIfPresent(String.self, forKey: .license),
                checkedAt: checkedAt)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .youtube(key, url, publisher, language, checkedAt):
            try c.encode("youtube", forKey: .provider)
            try c.encode(key, forKey: .key)
            try c.encode(url, forKey: .url)
            try c.encode(publisher, forKey: .publisher)
            try c.encode(language, forKey: .language)
            try c.encode(checkedAt, forKey: .checkedAt)
        case let .direct(url, sourceUrl, publisher, language, license, checkedAt):
            try c.encode("direct", forKey: .provider)
            try c.encode(url, forKey: .url)
            try c.encode(sourceUrl, forKey: .sourceUrl)
            try c.encode(publisher, forKey: .publisher)
            try c.encode(language, forKey: .language)
            try c.encode(license, forKey: .license)
            try c.encode(checkedAt, forKey: .checkedAt)
        }
    }

    public var publisher: String {
        switch self {
        case let .youtube(_, _, publisher, _, _), let .direct(_, _, publisher, _, _, _): publisher
        }
    }

    /// Where to watch it large or in a better quality.
    public var sourceURL: URL? {
        switch self {
        case let .youtube(_, url, _, _, _): URL(string: url)
        case let .direct(url, sourceUrl, _, _, _, _): URL(string: sourceUrl ?? url)
        }
    }
}

public struct Credit: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var role: String?
}

/// Lumos's request to the media server for a title on a list.
public struct RequestState: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pending, sent, exists, dropped, failed }

    public var status: Status
    public var seasons: [Int]?
    public var error: String?
    public var attempts: Int
    public var nextAttemptAt: String?
    public var updatedAt: String

    /// What the inspector says; nil when there is nothing to say.
    public var label: String? {
        let seasons = seasons.map { list in
            " (seizoen " + list.map(String.init).joined(separator: ", ") + ")"
        } ?? ""
        switch status {
        case .pending:
            return error.map { "\($0). Lumos probeert het opnieuw." } ?? "Wordt zo aangevraagd\(seasons). Z maakt het ongedaan."
        case .sent: return "Aangevraagd bij Seerr\(seasons)"
        case .exists: return "Al bekend bij Seerr; niets extra aangevraagd"
        case .dropped: return nil
        case .failed: return "Aanvragen lukte niet: \(error ?? "onbekende fout")"
        }
    }
}

public struct Download: Codable, Sendable, Equatable {
    public var progress: Double
    public var eta: String?
}

public struct TitleDetail: Codable, Sendable {
    public var dataOrigin: DataOrigin
    public var mediaType: MediaType
    public var tmdbId: Int
    public var title: String
    public var year: Int?
    public var runtimeMinutes: Int?
    public var seasons: Int?
    public var genres: [String]
    public var traits: [String]
    public var language: String?
    public var poster: String?
    public var backdrop: String?
    public var availability: Availability
    public var hasTrailer: Bool
    public var onList: Bool
    public var onShared: Bool
    public var onMine: Bool
    public var pass: VerdictRef?
    public var taste: VerdictRef?
    public var match: String?
    public var synopsis: String?
    public var synopsisLanguage: String?
    public var credits: [Credit]
    public var scores: [Score]
    public var snippets: [Snippet]
    public var trailer: Trailer?
    public var stills: [String]
    public var stillsCredit: String?
    public var tmdbUrl: String?
    public var request: RequestState?
    public var download: Download?

    public var ref: TitleRef { TitleRef(mediaType: mediaType, tmdbId: tmdbId) }

    public var summary: TitleSummary {
        TitleSummary(
            mediaType: mediaType, tmdbId: tmdbId, title: title, year: year, runtimeMinutes: runtimeMinutes,
            seasons: seasons, genres: genres, traits: traits, language: language, poster: poster, backdrop: backdrop,
            availability: availability, hasTrailer: hasTrailer, onList: onList, onShared: onShared, onMine: onMine,
            pass: pass, taste: taste, match: match)
    }
}

public struct TitleRow: Codable, Sendable, Identifiable {
    public enum Style: String, Codable, Sendable { case wide, poster }

    public var key: String
    public var title: String
    public var subtitle: String?
    public var style: Style
    public var items: [TitleSummary]
    public var empty: String?
    /// Pages other than Ontdekken show their titles as a grid.
    public var grid: Bool = false

    public var id: String { key }

    enum CodingKeys: String, CodingKey { case key, title, subtitle, style, items, empty }

    public init(key: String, title: String, subtitle: String? = nil, style: Style = .poster, items: [TitleSummary], empty: String? = nil, grid: Bool = false) {
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.items = items
        self.empty = empty
        self.grid = grid
    }
}

public struct RowsResponse: Codable, Sendable {
    public var dataOrigin: DataOrigin
    public var rows: [TitleRow]
}

public struct TitlesResponse: Codable, Sendable {
    public var dataOrigin: DataOrigin
    public var items: [TitleSummary]
}

public struct SearchResponse: Codable, Sendable {
    public struct Hit: Codable, Sendable {
        public var title: TitleSummary
        public var why: String?
    }

    public var dataOrigin: DataOrigin
    public var query: String
    public var hits: [Hit]
    public var credits: [Credit]
}

public struct ListEntry: Codable, Sendable {
    public var title: TitleSummary
    public var addedBy: Person
    public var addedAt: Date
    public var seasons: [Int]?
}

public struct ListResponse: Codable, Sendable {
    public var scope: ListScope
    public var items: [ListEntry]
}

public struct Verdict: Codable, Sendable, Identifiable {
    public var id: String
    public var scope: ListScope
    public var kind: VerdictKind
    public var reason: String?
    public var by: Person
    public var createdAt: Date
    public var title: TitleSummary
}

public struct VerdictsResponse: Codable, Sendable {
    public var scope: ListScope
    public var items: [Verdict]
}

public struct LumosStatus: Codable, Sendable {
    public var dataOrigin: DataOrigin?
    public var catalogue: String?
    /// Putting a title on a list requests it from the media server.
    public var requests: Bool?
}

public struct LumosChange: Codable, Sendable {
    public var changeId: String
}

extension APIClient {
    private func scoped(_ scope: ListScope, _ more: [URLQueryItem] = []) -> [URLQueryItem] {
        [URLQueryItem(name: "scope", value: scope.rawValue)] + more
    }

    public func lumosStatus() async throws -> LumosStatus { try await call("GET", "api/lumos/status") }

    public func rows(scope: ListScope) async throws -> RowsResponse {
        try await call("GET", "api/lumos/rows", query: scoped(scope))
    }

    public func titles(scope: ListScope, type: MediaType? = nil, available: Bool = false) async throws -> TitlesResponse {
        var more: [URLQueryItem] = []
        if let type { more.append(URLQueryItem(name: "type", value: type.rawValue)) }
        if available { more.append(URLQueryItem(name: "available", value: "true")) }
        return try await call("GET", "api/lumos/titles", query: scoped(scope, more))
    }

    public func search(titles query: String, scope: ListScope) async throws -> SearchResponse {
        try await call("GET", "api/lumos/search", query: scoped(scope, [URLQueryItem(name: "q", value: query)]))
    }

    public func title(_ ref: TitleRef, scope: ListScope) async throws -> TitleDetail {
        try await call("GET", "api/lumos/titles/\(ref.mediaType.rawValue)/\(ref.tmdbId)", query: scoped(scope))
    }

    public func similar(to ref: TitleRef, scope: ListScope) async throws -> TitlesResponse {
        try await call("GET", "api/lumos/similar/\(ref.mediaType.rawValue)/\(ref.tmdbId)", query: scoped(scope))
    }

    public func list(_ scope: ListScope) async throws -> ListResponse {
        try await call("GET", "api/lumos/lists/\(scope.rawValue)")
    }

    public func verdicts(_ scope: ListScope) async throws -> VerdictsResponse {
        try await call("GET", "api/lumos/verdicts", query: scoped(scope))
    }

    public func addToList(_ ref: TitleRef, scope: ListScope) async throws -> LumosChange {
        try await call("PUT", "api/lumos/lists/\(scope.rawValue)/items/\(ref.mediaType.rawValue)/\(ref.tmdbId)", body: [String: String]())
    }

    public func removeFromList(_ ref: TitleRef, scope: ListScope) async throws -> LumosChange {
        try await call("DELETE", "api/lumos/lists/\(scope.rawValue)/items/\(ref.mediaType.rawValue)/\(ref.tmdbId)")
    }

    struct NewVerdict: Encodable {
        var scope: String
        var mediaType: String
        var tmdbId: Int
        var kind: String
        var reason: String?
    }

    public func addVerdict(_ kind: VerdictKind, _ ref: TitleRef, scope: ListScope, reason: String? = nil) async throws -> LumosChange {
        try await call(
            "POST", "api/lumos/verdicts",
            body: NewVerdict(scope: scope.rawValue, mediaType: ref.mediaType.rawValue, tmdbId: ref.tmdbId, kind: kind.rawValue, reason: reason))
    }

    public func undoVerdict(_ id: String) async throws -> LumosChange {
        try await call("DELETE", "api/lumos/verdicts/\(id)")
    }

    struct Done: Decodable { var ok: Bool }

    public func retryRequest(_ ref: TitleRef) async throws {
        let _: Done = try await call("POST", "api/lumos/requests/\(ref.mediaType.rawValue)/\(ref.tmdbId)/retry")
    }

    public func undo(change id: String) async throws -> LumosChange {
        try await call("POST", "api/lumos/changes/\(id)/undo")
    }
}
