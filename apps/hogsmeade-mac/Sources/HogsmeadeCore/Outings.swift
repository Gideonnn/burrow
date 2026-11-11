import Foundation

// Swift mirrors of packages/contracts/src/outings.ts. An outing (Evenement)
// belongs to the whole household; tickets never go to a cloud model.

public struct PersonRef: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
}

public struct OutingTicket: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var contentType: String
    public var size: Int
    public var holder: String?
    public var personalised: Bool
    public var messageId: String?
    public var addedBy: PersonRef
    public var addedAt: Date
}

public struct OutingTask: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case personalise, calendar, custom }
    public var id: String
    public var kind: Kind
    public var title: String
    public var dueAt: Date?
    public var assignee: PersonRef?
    public var doneAt: Date?
    public var doneBy: PersonRef?

    public var done: Bool { doneAt != nil }
}

public struct OutingMail: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var visible: Bool
    public var owner: PersonRef
    public var subject: String?
    public var from: Address?
    public var receivedAt: Date
}

public struct Outing: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var kind: String?
    public var startsAt: Date
    public var endsAt: Date?
    public var doorsAt: Date?
    public var allDay: Bool
    public var venue: String?
    public var address: String?
    public var organiser: String?
    public var vendor: String?
    public var orderNumber: String?
    public var url: String?
    public var notes: String
    public var aliases: [String]
    public var inCalendar: Bool
    /// Optional, so a server without pictures still decodes.
    public var image: OutingImage?
    public var attendees: [PersonRef]
    public var tickets: [OutingTicket]
    public var tasks: [OutingTask]
    public var mails: [OutingMail]
    /// Optional, so an older server still decodes; read `shopLinks`.
    public var ticketLinks: [OutingTicketLink]?
    /// Nil without a line-up, and from an older server.
    public var lineup: OutingLineup?
    public var createdBy: PersonRef
    public var createdAt: Date
    public var updatedBy: PersonRef
    public var updatedAt: Date

    /// The checklist without the old "In de agenda zetten" items: calendar
    /// sync is automatic, so nobody ticks that by hand.
    public var checklist: [OutingTask] { tasks.filter { $0.kind != .calendar } }
}

public struct OutingImage: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        case mail, website, upload

        // A source a newer server adds must not hide every outing.
        public init(from decoder: Decoder) throws {
            self = Source(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .upload
        }
    }

    public var source: Source
    public var contentType: String
    public var updatedAt: Date
    /// How someone placed it in the header; nil is centred.
    public var frame: PictureFrame?
}

/// A picture the server found in the outing's mail or on its website.
public struct OutingImageOption: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var source: OutingImage.Source
}

/// Body of PUT /api/outings/:id/image.
public enum SetOutingImageRequest: Encodable, Equatable, Sendable {
    case option(String)
    case upload(String)
    case link(URL)

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .option(let id): try c.encode(["optionId": id])
        case .upload(let id): try c.encode(["uploadId": id])
        case .link(let url): try c.encode(["url": url.absoluteString])
        }
    }
}

/// A linked mail as Hogsmeade shows it: as text, without the rest of a message.
public struct LinkedMail: Decodable, Sendable {
    public var subject: String
    public var from: Address
    public var snippet: String
    public var bodyText: String?
}

extension APIClient {
    public func outings() async throws -> [Outing] { try await call("GET", "api/outings") }

    public func outing(id: String) async throws -> Outing { try await call("GET", "api/outings/\(id)") }

    /// Who goes is left out: the server adds everyone.
    public func createOuting(title: String, startsAt: Date, kind: String?, venue: String?) async throws -> Outing {
        var body: [String: JSONValue] = ["title": .string(title), "startsAt": .string(Self.isoFractional.string(from: startsAt))]
        if let kind { body["kind"] = .string(kind) }
        if let venue { body["venue"] = .string(venue) }
        return try await call("POST", "api/outings", body: body)
    }

    public func setOutingTask(outingId: String, taskId: String, done: Bool) async throws -> Outing {
        try await call("PATCH", "api/outings/\(outingId)/tasks/\(taskId)", body: ["done": done])
    }

    public func addOutingTask(outingId: String, title: String, dueAt: Date?) async throws -> Outing {
        var body: [String: JSONValue] = ["title": .string(title)]
        if let dueAt { body["dueAt"] = .string(Self.isoFractional.string(from: dueAt)) }
        return try await call("POST", "api/outings/\(outingId)/tasks", body: body)
    }

    /// A partial update; `.null` clears a field.
    public func updateOuting(id: String, _ patch: [String: JSONValue]) async throws -> Outing {
        try await call("PATCH", "api/outings/\(id)", body: patch)
    }

    public func deleteOuting(id: String) async throws {
        let _: Empty = try await call("DELETE", "api/outings/\(id)")
    }

    /// Keeps an uploaded file (see `upload(file:)`) as a ticket.
    public func addTicket(outingId: String, uploadId: String, name: String) async throws -> Outing {
        try await call("POST", "api/outings/\(outingId)/tickets", body: ["uploadId": uploadId, "name": name])
    }

    public func updateTicket(outingId: String, ticketId: String, _ patch: [String: JSONValue]) async throws -> Outing {
        try await call("PATCH", "api/outings/\(outingId)/tickets/\(ticketId)", body: patch)
    }

    public func deleteTicket(outingId: String, ticketId: String) async throws -> Outing {
        try await call("DELETE", "api/outings/\(outingId)/tickets/\(ticketId)")
    }

    /// The picture's bytes; `version` makes a changed picture a new URL, so
    /// no cache hands out the old one.
    public func outingImage(outingId: String, version: Date) async throws -> Data {
        let v = URLQueryItem(name: "v", value: String(Int(version.timeIntervalSince1970 * 1000)))
        return try await bytes(request("GET", "api/outings/\(outingId)/image", query: [v]))
    }

    public func outingImageOptions(outingId: String) async throws -> [OutingImageOption] {
        struct Response: Decodable { var options: [OutingImageOption] }
        let response: Response = try await call("GET", "api/outings/\(outingId)/image/options")
        return response.options
    }

    /// An option's picture, fetched by the server: the Mac never loads it from outside.
    public func outingImageOption(outingId: String, optionId: String) async throws -> Data {
        try await bytes(request("GET", "api/outings/\(outingId)/image/options/\(optionId)"))
    }

    public func setOutingImage(outingId: String, _ body: SetOutingImageRequest) async throws -> Outing {
        try await call("PUT", "api/outings/\(outingId)/image", body: body)
    }

    /// Starts reading the line-up from the website; the outing says working
    /// until `outing.changed` brings the result.
    public func refreshLineup(outingId: String) async throws -> Outing {
        try await call("POST", "api/outings/\(outingId)/lineup")
    }

    public func removeLineup(outingId: String) async throws -> Outing {
        try await call("DELETE", "api/outings/\(outingId)/lineup")
    }

    /// No picture, and Hedwig does not pick one again by itself.
    public func deleteOutingImage(outingId: String) async throws -> Outing {
        try await call("DELETE", "api/outings/\(outingId)/image")
    }

    private func bytes(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.data(for: request)
        try Self.check(response, bytes)
        return bytes
    }

    public func linkMail(outingId: String, messageId: String) async throws -> Outing {
        try await call("POST", "api/outings/\(outingId)/mails", body: ["messageId": messageId])
    }

    public func unlinkMail(outingId: String, messageId: String) async throws -> Outing {
        try await call("DELETE", "api/outings/\(outingId)/mails/\(messageId)")
    }

    public func linkedMail(id: String) async throws -> LinkedMail { try await call("GET", "api/messages/\(id)") }

    /// The ticket's file, for Quick Look or the printer.
    public func ticketFile(outingId: String, ticketId: String) async throws -> Data {
        try await bytes(request("GET", "api/outings/\(outingId)/tickets/\(ticketId)/file"))
    }
}
