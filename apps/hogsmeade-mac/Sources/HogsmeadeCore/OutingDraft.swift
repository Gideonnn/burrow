import Foundation

/// The edit sheet's fields; `patch` holds only what changed.
public struct OutingDraft: Equatable, Sendable {
    public var title: String
    public var kind: String
    public var startsAt: Date
    public var hasDoors: Bool
    public var doorsAt: Date
    public var hasEnd: Bool
    public var endsAt: Date
    public var venue: String
    public var address: String
    public var notes: String

    public init(_ outing: Outing) {
        title = outing.title
        kind = outing.kind ?? ""
        startsAt = outing.startsAt
        hasDoors = outing.doorsAt != nil
        doorsAt = outing.doorsAt ?? outing.startsAt.addingTimeInterval(-30 * 60)
        hasEnd = outing.endsAt != nil
        endsAt = outing.endsAt ?? outing.startsAt.addingTimeInterval(3 * 3600)
        venue = outing.venue ?? ""
        address = outing.address ?? ""
        notes = outing.notes
    }

    public func patch(against outing: Outing) -> [String: JSONValue] {
        var patch: [String: JSONValue] = [:]
        let clean = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let date = { (date: Date) in JSONValue.string(APIClient.isoFractional.string(from: date)) }
        let optional = { (key: String, text: String, old: String?) in
            let value = clean(text)
            if value != (old ?? "") { patch[key] = value.isEmpty ? .null : .string(value) }
        }
        let name = clean(title)
        if !name.isEmpty, name != outing.title { patch["title"] = .string(name) }
        optional("kind", kind, outing.kind)
        if startsAt != outing.startsAt { patch["startsAt"] = date(startsAt) }
        let doors = hasDoors ? doorsAt : nil
        if doors != outing.doorsAt { patch["doorsAt"] = doors.map(date) ?? .null }
        let end = hasEnd ? endsAt : nil
        if end != outing.endsAt { patch["endsAt"] = end.map(date) ?? .null }
        optional("venue", venue, outing.venue)
        optional("address", address, outing.address)
        if clean(notes) != outing.notes { patch["notes"] = .string(clean(notes)) }
        return patch
    }
}

extension APIClient {
    public func linkMail(outingId: String, messageId: String) async throws -> Outing {
        try await call("POST", "api/outings/\(outingId)/mails", body: ["messageId": messageId])
    }

    public func unlinkMail(outingId: String, messageId: String) async throws -> Outing {
        try await call("DELETE", "api/outings/\(outingId)/mails/\(messageId)")
    }
}
