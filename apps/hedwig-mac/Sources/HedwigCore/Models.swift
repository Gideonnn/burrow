import Foundation

// Swift mirrors of packages/contracts. Field names match the JSON exactly.

public struct Address: Codable, Hashable, Sendable {
    public var name: String?
    public var email: String

    public init(name: String? = nil, email: String) {
        self.name = name
        self.email = email
    }

    public var display: String { name?.isEmpty == false ? name! : email }

    /// Parses "Name <a@b>" or a bare address; used by the composer fields.
    public static func parseList(_ text: String) -> [Address] {
        text.split(separator: ",").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if let open = trimmed.firstIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
                let name = trimmed[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                let email = String(trimmed[trimmed.index(after: open)..<close])
                return Address(name: name.isEmpty ? nil : name, email: email)
            }
            return Address(email: trimmed)
        }
    }

    public static func format(_ list: [Address]) -> String {
        list.map { address in
            address.name.map { "\($0) <\(address.email)>" } ?? address.email
        }.joined(separator: ", ")
    }
}

public enum MailProvider: String, Codable, Sendable {
    case gmail, microsoft, fastmail
}

public enum MailFolder: String, Codable, Sendable, CaseIterable {
    case inbox, archive, spam, trash, sent
}

public enum Right: String, Codable, Sendable {
    case read, organize, draft, send, tasks, admin
}

public struct MailboxSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var ownerId: String
    public var provider: MailProvider
    public var address: String
    public var name: String
}

public struct Me: Codable, Sendable {
    public struct Person: Codable, Sendable { public var id: String; public var name: String }
    public struct Key: Codable, Sendable { public var id: String; public var name: String }
    public var person: Person
    public var key: Key
    public var rights: [Right]
    public var mailboxes: [MailboxSummary]

    public func can(_ right: Right) -> Bool { rights.contains(right) }
}

public struct MessageSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var mailboxId: String
    public var threadId: String?
    public var from: Address
    public var to: [Address]
    public var subject: String
    public var snippet: String
    public var receivedAt: Date
    public var folder: MailFolder
    public var unread: Bool
    public var flagged: Bool
    public var labels: [String]
    public var hasAttachments: Bool
}

public struct MessageDetail: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var mailboxId: String
    public var threadId: String?
    public var from: Address
    public var to: [Address]
    public var cc: [Address]
    public var subject: String
    public var snippet: String
    public var receivedAt: Date
    public var folder: MailFolder
    public var unread: Bool
    public var flagged: Bool
    public var labels: [String]
    public var hasAttachments: Bool
    public var bodyText: String?
    public var bodyHtml: String?

    public var summary: MessageSummary {
        MessageSummary(
            id: id, mailboxId: mailboxId, threadId: threadId, from: from, to: to, subject: subject,
            snippet: snippet, receivedAt: receivedAt, folder: folder, unread: unread, flagged: flagged,
            labels: labels, hasAttachments: hasAttachments)
    }
}

public enum ServerOp: Codable, Hashable, Sendable {
    case markRead, markUnread, moveToSpam, moveToInbox, archive, trash, flag, unflag
    case addLabel(String), removeLabel(String)

    enum CodingKeys: String, CodingKey { case op, label }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addLabel(let label):
            try c.encode("addLabel", forKey: .op)
            try c.encode(label, forKey: .label)
        case .removeLabel(let label):
            try c.encode("removeLabel", forKey: .op)
            try c.encode(label, forKey: .label)
        default:
            try c.encode(String(describing: self), forKey: .op)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "markRead": self = .markRead
        case "markUnread": self = .markUnread
        case "moveToSpam": self = .moveToSpam
        case "moveToInbox": self = .moveToInbox
        case "archive": self = .archive
        case "trash": self = .trash
        case "flag": self = .flag
        case "unflag": self = .unflag
        case "addLabel": self = .addLabel(try c.decode(String.self, forKey: .label))
        case "removeLabel": self = .removeLabel(try c.decode(String.self, forKey: .label))
        default: throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op \(op)")
        }
    }
}

public struct TriageAction: Codable, Hashable, Sendable {
    public var kind: String
    public var label: String?
}

public struct FilteredEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var bot: String
    public var action: TriageAction
    public var reason: String
    public var unsure: Bool
    public var serverOps: [String]
    public var createdAt: Date
    public var message: MessageSummary
}

public struct Draft: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var mailboxId: String
    public var createdBy: String
    public var inReplyTo: String?
    public var to: [Address]
    public var cc: [Address]
    public var subject: String
    public var body: String
    public var createdAt: Date
}

public struct LearnedRule: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var createdAt: Date
}

public struct Person: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
}

/// What the composer edits, and what opens a compose window.
public struct ComposeDraft: Codable, Hashable, Sendable {
    public var mailboxId: String
    public var to: String
    public var cc: String
    public var subject: String
    public var body: String
    public var inReplyTo: String?
    /// The server draft this came from, deleted after sending.
    public var serverDraftId: String?

    public init(
        mailboxId: String, to: String = "", cc: String = "", subject: String = "", body: String = "",
        inReplyTo: String? = nil, serverDraftId: String? = nil
    ) {
        self.mailboxId = mailboxId
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.serverDraftId = serverDraftId
    }
}

public struct SendRequest: Codable, Sendable {
    public var mailboxId: String
    public var to: [Address]
    public var cc: [Address]
    public var subject: String
    public var body: String
    public var inReplyTo: String?
}
