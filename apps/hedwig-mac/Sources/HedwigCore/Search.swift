import BurrowKit
import Foundation

/// Where a search result matched: a piece of the body with the matched words
/// as `[start, length]` in UTF-16 units.
public struct SearchHit: Codable, Hashable, Sendable {
    public var field: String
    public var text: String
    public var ranges: [[Int]]

    public init(field: String, text: String, ranges: [[Int]]) {
        self.field = field
        self.text = text
        self.ranges = ranges
    }

    /// The text with every match marked, for the list.
    public var marked: AttributedString {
        var out = AttributedString(text)
        let utf16 = text.utf16
        for range in ranges where range.count == 2 {
            guard let start = utf16.index(utf16.startIndex, offsetBy: range[0], limitedBy: utf16.endIndex),
                  let end = utf16.index(start, offsetBy: range[1], limitedBy: utf16.endIndex),
                  let lower = AttributedString.Index(start, within: out),
                  let upper = AttributedString.Index(end, within: out)
            else { continue }
            out[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            out[lower..<upper].searchMatch = true
        }
        return out
    }
}

/// Marks the matched words, so the view can give them a background.
public enum SearchMatchAttribute: AttributedStringKey {
    public typealias Value = Bool
    public static let name = "hedwig.searchMatch"
}

extension AttributeScopes {
    public struct HedwigAttributes: AttributeScope {
        public let searchMatch: SearchMatchAttribute
    }
    public var hedwig: HedwigAttributes.Type { HedwigAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.HedwigAttributes, T>) -> T { self[T.self] }
}

/// A chip in the search field: someone, a period, a kind of mail, or (from
/// the bot's plan) a group of words. `key` names the part of the plan it
/// stands for, so removing it reruns the plan without that part.
public enum SearchToken: Codable, Hashable, Identifiable, Sendable {
    case person(key: String, label: String, emails: [String])
    case period(key: String, label: String, after: String?, before: String?)
    case category(key: String, label: String, category: String)
    case attachments(key: String, label: String)
    case unread(key: String, label: String)
    case words(key: String, label: String, words: [String])

    public var id: String { key }

    public var key: String {
        switch self {
        case .person(let k, _, _), .period(let k, _, _, _), .category(let k, _, _), .attachments(let k, _), .unread(let k, _), .words(let k, _, _): k
        }
    }

    public var label: String {
        switch self {
        case .person(_, let l, _), .period(_, let l, _, _), .category(_, let l, _), .attachments(_, let l), .unread(_, let l), .words(_, let l, _): l
        }
    }

    public var systemImage: String {
        switch self {
        case .person(_, _, let emails): emails.first?.hasPrefix("@") == true ? "building.2" : "person.crop.circle"
        case .period: "calendar"
        case .category: "tag"
        case .attachments: "paperclip"
        case .unread: "envelope.badge"
        case .words: "text.magnifyingglass"
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, key, label, emails, after, before, category, words }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let key = try c.decode(String.self, forKey: .key)
        let label = try c.decode(String.self, forKey: .label)
        switch try c.decode(String.self, forKey: .kind) {
        case "person": self = .person(key: key, label: label, emails: try c.decode([String].self, forKey: .emails))
        case "period":
            self = .period(key: key, label: label, after: try c.decodeIfPresent(String.self, forKey: .after),
                           before: try c.decodeIfPresent(String.self, forKey: .before))
        case "category": self = .category(key: key, label: label, category: try c.decode(String.self, forKey: .category))
        case "attachments": self = .attachments(key: key, label: label)
        case "unread": self = .unread(key: key, label: label)
        default: self = .words(key: key, label: label, words: (try? c.decode([String].self, forKey: .words)) ?? [label])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(label, forKey: .label)
        switch self {
        case .person(_, _, let emails): try c.encode("person", forKey: .kind); try c.encode(emails, forKey: .emails)
        case .period(_, _, let after, let before):
            try c.encode("period", forKey: .kind); try c.encode(after, forKey: .after); try c.encode(before, forKey: .before)
        case .category(_, _, let category): try c.encode("category", forKey: .kind); try c.encode(category, forKey: .category)
        case .attachments: try c.encode("attachments", forKey: .kind)
        case .unread: try c.encode("unread", forKey: .kind)
        case .words(_, _, let words): try c.encode("words", forKey: .kind); try c.encode(words, forKey: .words)
        }
    }
}

/// Someone the person mails with, for @name.
public struct MailPerson: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var emails: [String]
    public var sent: Int
    public var received: Int
    public var lastAt: Date
    public var domain: Bool?

    public var id: String { emails.first ?? name }

    public var token: SearchToken {
        .person(key: "field:person:\(id)", label: domain == true ? "@\(name)" : name, emails: emails)
    }

    /// "12× gemaild · jan@example.com", for the suggestion.
    public var detail: String {
        let count = sent + received
        let address = domain == true ? "iedereen bij \(name)" : (emails.first ?? "")
        return count > 0 ? "\(count)× · \(address)" : address
    }
}

public struct PeopleResponse: Codable, Sendable { public var people: [MailPerson] }

public struct SearchAnswer: Codable, Hashable, Sendable {
    public var text: String
    public var messageIds: [String]
}

public struct RankResponse: Codable, Sendable {
    public var results: [MessageSummary]
    public var relevant: Int
    public var answer: SearchAnswer?
}

/// What the field's chips add to the words.
public struct SearchFilters: Codable, Hashable, Sendable {
    public var people: [String] = []
    public var after: String?
    public var before: String?
    public var categories: [String]?
    public var hasAttachments = false
    public var unreadOnly = false

    public init(tokens: [SearchToken]) {
        for token in tokens {
            switch token {
            case .person(_, _, let emails): people += emails
            case .period(_, _, let a, let b): after = a; before = b
            case .category(_, _, let c): categories = (categories ?? []) + [c]
            case .attachments: hasAttachments = true
            case .unread: unreadOnly = true
            case .words: break
            }
        }
    }

    public var isEmpty: Bool { people.isEmpty && after == nil && before == nil && (categories ?? []).isEmpty && !hasAttachments && !unreadOnly }

    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if !people.isEmpty { items.append(URLQueryItem(name: "people", value: people.joined(separator: ","))) }
        if let after { items.append(URLQueryItem(name: "after", value: after)) }
        if let before { items.append(URLQueryItem(name: "before", value: before)) }
        if let categories, !categories.isEmpty { items.append(URLQueryItem(name: "kinds", value: categories.joined(separator: ","))) }
        if hasAttachments { items.append(URLQueryItem(name: "attachments", value: "true")) }
        if unreadOnly { items.append(URLQueryItem(name: "unread", value: "true")) }
        return items
    }
}

public enum SearchSort: String, CaseIterable, Sendable { case best, newest }

/// A suggestion under the field: a chip to add, and a line about it.
public struct SearchSuggestion: Hashable, Identifiable, Sendable {
    public var token: SearchToken
    public var detail: String?
    /// How many of the last typed words the chip replaces.
    public var replaces = 1
    public var id: String { token.key }

    public init(token: SearchToken, detail: String?, replaces: Int = 1) {
        self.token = token
        self.detail = detail
        self.replaces = replaces
    }

    /// The field's text once the chip took the place of its words.
    public func text(after typed: String) -> String {
        let words = typed.split(separator: " ").dropLast(replaces)
        return words.isEmpty ? "" : words.joined(separator: " ") + " "
    }
}

/// A one-click narrowing above the results, drawn from what they contain.
public struct SearchLens: Hashable, Identifiable, Sendable {
    public var token: SearchToken
    public var count: Int
    // Every year is a period with the same key, so the label tells them apart.
    public var id: String { "\(token.id)|\(token.label)" }
}

/// Recognises the words a person types for a period, a kind of mail or a
/// flag, so the field can offer them as chips. Dutch first, English too.
public enum SearchWords {
    static let months = ["januari", "februari", "maart", "april", "mei", "juni", "juli", "augustus", "september", "oktober", "november", "december"]
    static let shortMonths = ["jan", "feb", "mrt", "apr", "mei", "jun", "jul", "aug", "sep", "okt", "nov", "dec"]
    static let englishMonths = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    static let categories: [(words: [String], category: String, label: String)] = [
        (["factuur", "facturen", "rekening", "rekeningen", "nota", "invoice"], "invoice", "Facturen"),
        (["bestelling", "bestellingen", "order", "orders", "aankoop"], "order", "Bestellingen"),
        (["pakket", "pakketje", "pakketten", "verzending", "zending", "levering"], "shipping", "Pakketten"),
        (["reis", "reizen", "vlucht", "vluchten", "hotel", "boeking", "trein"], "travel", "Reizen"),
        (["afspraak", "afspraken", "uitnodiging"], "appointment", "Afspraken"),
        (["bank", "betaling", "overboeking"], "bank", "Bank"),
        (["school", "studie", "rooster", "tentamen", "college"], "school", "School"),
        (["werk", "klant", "klanten", "offerte", "offertes"], "work", "Werk"),
        (["gemeente", "belasting", "belastingdienst", "overheid"], "government", "Overheid"),
        (["zorg", "huisarts", "ziekenhuis", "verzekeraar"], "health", "Gezondheid"),
        (["nieuwsbrief", "nieuwsbrieven", "newsletter"], "newsletter", "Nieuwsbrieven"),
        (["code", "codes", "inlogcode", "verificatie"], "code", "Codes"),
    ]

    private static func iso(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// A period for a typed word: "maart", "2024", "vorige week", "vorig jaar".
    public static func period(for phrase: String, now: Date = Date(), calendar: Calendar = .current) -> SearchToken? {
        let w = phrase.lowercased().trimmingCharacters(in: .whitespaces)
        guard w.count >= 3 else { return nil }
        let year = calendar.component(.year, from: now)
        func token(_ label: String, _ start: Date, _ end: Date) -> SearchToken {
            .period(key: "field:period", label: label, after: iso(start, calendar), before: iso(end, calendar))
        }
        func month(_ index: Int, _ y: Int) -> SearchToken {
            let start = calendar.date(from: DateComponents(year: y, month: index + 1, day: 1))!
            return token("\(months[index]) \(y)", start, calendar.date(byAdding: .month, value: 1, to: start)!)
        }
        if let y = Int(w), (1990...year).contains(y) {
            let start = calendar.date(from: DateComponents(year: y, month: 1, day: 1))!
            return token("\(y)", start, calendar.date(byAdding: .year, value: 1, to: start)!)
        }
        for (i, name) in months.enumerated() where name.hasPrefix(w) || englishMonths[i].hasPrefix(w) || shortMonths[i] == w {
            // The most recent such month that is not in the future.
            let thisMonth = calendar.component(.month, from: now)
            return month(i, i + 1 <= thisMonth ? year : year - 1)
        }
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let week = calendar.dateInterval(of: .weekOfYear, for: now)!
        let monthStart = calendar.dateInterval(of: .month, for: now)!.start
        let yearStart = calendar.dateInterval(of: .year, for: now)!.start
        let named: [(String, () -> SearchToken)] = [
            ("vandaag", { token("vandaag", today, tomorrow) }),
            ("gisteren", { token("gisteren", calendar.date(byAdding: .day, value: -1, to: today)!, today) }),
            ("deze week", { token("deze week", week.start, tomorrow) }),
            ("vorige week", { token("vorige week", calendar.date(byAdding: .weekOfYear, value: -1, to: week.start)!, week.start) }),
            ("deze maand", { token("deze maand", monthStart, tomorrow) }),
            ("vorige maand", { token("vorige maand", calendar.date(byAdding: .month, value: -1, to: monthStart)!, monthStart) }),
            ("dit jaar", { token("dit jaar", yearStart, tomorrow) }),
            ("vorig jaar", { token("vorig jaar", calendar.date(byAdding: .year, value: -1, to: yearStart)!, yearStart) }),
        ]
        return named.first { $0.0.hasPrefix(w) }?.1()
    }

    public static func category(for word: String) -> SearchToken? {
        let w = word.lowercased()
        guard w.count >= 4 else { return nil }
        guard let match = categories.first(where: { entry in entry.words.contains { $0.hasPrefix(w) } }) else { return nil }
        return .category(key: "field:category:\(match.category)", label: match.label, category: match.category)
    }

    public static func flag(for word: String) -> SearchToken? {
        let w = word.lowercased()
        guard w.count >= 4 else { return nil }
        if "bijlage".hasPrefix(w) || "bijlagen".hasPrefix(w) || "attachment".hasPrefix(w) { return .attachments(key: "field:attachments", label: "Met bijlage") }
        if "ongelezen".hasPrefix(w) || "unread".hasPrefix(w) { return .unread(key: "field:unread", label: "Ongelezen") }
        return nil
    }

    /// Chips the last words of the field could become.
    public static func suggestions(for text: String, now: Date = Date()) -> [SearchSuggestion] {
        let words = text.split(separator: " ").map(String.init)
        guard let last = words.last, !text.hasSuffix(" ") else { return [] }
        var out: [SearchSuggestion] = []
        if words.count >= 2, ["deze", "vorige", "vorig", "dit"].contains(words[words.count - 2].lowercased()),
           let p = period(for: "\(words[words.count - 2]) \(last)", now: now) {
            out.append(SearchSuggestion(token: p, detail: "periode", replaces: 2))
        } else if let p = period(for: last, now: now) {
            out.append(SearchSuggestion(token: p, detail: "periode"))
        }
        if let c = category(for: last) { out.append(SearchSuggestion(token: c, detail: "soort mail")) }
        if let f = flag(for: last) { out.append(SearchSuggestion(token: f, detail: nil)) }
        return out
    }

    /// The word being typed after an @, if any.
    public static func mention(in text: String) -> String? {
        guard !text.hasSuffix(" "), let last = text.split(separator: " ").last, last.hasPrefix("@") else { return nil }
        return String(last.dropFirst())
    }

    /// Lenses over the results: the people, kinds and years they hold, each
    /// worth a click only when it narrows.
    public static func lenses(for results: [MessageSummary], own: Set<String>, chosen: [SearchToken], calendar: Calendar = .current) -> [SearchLens] {
        guard results.count >= 4 else { return [] }
        let chosenKeys = Set(chosen.map(\.key))
        var lenses: [SearchLens] = []
        var senders: [String: (name: String, count: Int)] = [:]
        for m in results {
            let email = m.from.email.lowercased()
            guard !own.contains(email) else { continue }
            senders[email, default: (m.from.name ?? m.from.email, 0)].count += 1
        }
        for (email, s) in senders.sorted(by: { $0.value.count > $1.value.count }).prefix(3) where s.count >= 2 && s.count < results.count {
            let token = SearchToken.person(key: "field:person:\(email)", label: s.name, emails: [email])
            if !chosenKeys.contains(token.key) { lenses.append(SearchLens(token: token, count: s.count)) }
        }
        var kinds: [String: Int] = [:]
        for m in results { if let c = m.facts?.category { kinds[c, default: 0] += 1 } }
        for (kind, n) in kinds.sorted(by: { $0.value > $1.value }).prefix(2) where n >= 2 && n < results.count {
            guard let label = categories.first(where: { $0.category == kind })?.label else { continue }
            let token = SearchToken.category(key: "field:category:\(kind)", label: label, category: kind)
            if !chosenKeys.contains(token.key) { lenses.append(SearchLens(token: token, count: n)) }
        }
        let attached = results.filter(\.hasAttachments).count
        if attached > 0, attached < results.count, !chosenKeys.contains("field:attachments") {
            lenses.append(SearchLens(token: .attachments(key: "field:attachments", label: "Met bijlage"), count: attached))
        }
        var years: [Int: Int] = [:]
        for m in results { years[calendar.component(.year, from: m.receivedAt), default: 0] += 1 }
        if years.count > 1, !chosenKeys.contains("field:period") {
            for (y, n) in years.sorted(by: { $0.key > $1.key }).prefix(3) {
                if let token = period(for: String(y)) { lenses.append(SearchLens(token: token, count: n)) }
            }
        }
        return lenses
    }
}
