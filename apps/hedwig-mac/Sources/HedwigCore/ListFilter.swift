import Foundation

/// Mail's list filter: with the filter on, the list shows only mail that matches every criterion.
public enum ListFilter: String, CaseIterable, Codable, Sendable {
    case unread, flagged, attachments, toMe, today

    public var title: String {
        switch self {
        case .unread: "Ongelezen"
        case .flagged: "Antwoord nodig"
        case .attachments: "Met bijlagen"
        case .toMe: "Aan mij"
        case .today: "Van vandaag"
        }
    }

    public var systemImage: String {
        switch self {
        case .unread: "envelope.badge"
        case .flagged: "flag"
        case .attachments: "paperclip"
        case .toMe: "person"
        case .today: "calendar"
        }
    }

    /// Whether a message still matches, for mail that changed after the list loaded.
    func matches(_ message: MessageSummary, address: String?, now: Date = .now) -> Bool {
        switch self {
        case .unread: message.unread
        case .flagged: message.flagged
        case .attachments: message.hasAttachments
        case .toMe: message.to.contains { $0.email.lowercased() == address?.lowercased() }
        case .today: message.receivedAt >= Calendar.current.startOfDay(for: now)
        }
    }

    static func load(from defaults: UserDefaults) -> Set<ListFilter> {
        let stored = Set((defaults.string(forKey: defaultsKey) ?? "").split(separator: ",").compactMap { ListFilter(rawValue: String($0)) })
        return stored.isEmpty ? [.unread] : stored
    }

    static func save(_ criteria: Set<ListFilter>, to defaults: UserDefaults) {
        defaults.set(ordered(criteria).map(\.rawValue).joined(separator: ","), forKey: defaultsKey)
    }

    static func ordered(_ criteria: Set<ListFilter>) -> [ListFilter] { allCases.filter(criteria.contains) }

    private static let defaultsKey = "listFilter"
}

extension AppModel {
    /// Adds or removes a criterion; the last one stays, as in Mail.
    public func toggle(_ criterion: ListFilter) {
        if filterCriteria.contains(criterion) {
            guard filterCriteria.count > 1 else { return }
            filterCriteria.remove(criterion)
        } else {
            filterCriteria.insert(criterion)
        }
    }

    /// Whether the open list is filtered right now; search results never are.
    public var isFiltering: Bool { filterOn && !isSearching && placeScope != nil && selection != nil }

    /// The list header's subtitle while filtering.
    public var filterDescription: String? {
        guard isFiltering else { return nil }
        return "Gefilterd op: " + ListFilter.ordered(filterCriteria).map(\.title).joined(separator: ", ")
    }

    func matchesFilter(_ message: MessageSummary) -> Bool {
        guard isFiltering else { return true }
        let address = mailbox(message.mailboxId)?.address
        return filterCriteria.allSatisfy { $0.matches(message, address: address) }
    }

    /// What the server should filter on for the open list, or nil without a filter.
    var serverFilter: (criteria: [String], since: Date?)? {
        guard isFiltering else { return nil }
        let criteria = ListFilter.ordered(filterCriteria).filter { $0 != .today }.map(\.rawValue)
        let since = filterCriteria.contains(.today) ? Calendar.current.startOfDay(for: .now) : nil
        return (criteria, since)
    }
}
