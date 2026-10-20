import Foundation

// Swift mirrors of packages/contracts. Field names match the JSON exactly.

public enum MailProvider: String, Codable, Sendable {
    case gmail, microsoft, fastmail
}

public enum MailFolder: String, Codable, Sendable, CaseIterable {
    case inbox, archive, spam, trash, sent
}

/// What a mailbox is for; the sidebar groups by it and merges each group's inboxes.
public enum MailboxRole: String, Codable, Sendable, CaseIterable {
    case `private`, work, school
}

public struct MailboxSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var ownerId: String
    public var provider: MailProvider
    public var address: String
    public var name: String
    // Optional so an older server without roles still decodes.
    public var role: MailboxRole?
    /// Extra bot instructions for mail in this mailbox.
    public var instructions: String?

    public var kind: MailboxRole { role ?? .private }
}

public struct Me: Codable, Sendable {
    public struct Person: Codable, Sendable { public var id: String; public var name: String }
    public struct Key: Codable, Sendable { public var id: String; public var name: String }
    public var person: Person
    public var key: Key
    public var rights: [Right]
    public var mailboxes: [MailboxSummary]
    /// The language this person's bots write in; nil is the server's default.
    public var language: String?
    public var admin: Bool?
    public var settings: [String: SettingValue]?

    public func can(_ right: Right) -> Bool { rights.contains(right) }

    /// A feature or setting that is on for this person.
    public func enabled(_ setting: String) -> Bool {
        settings?[setting]?.bool ?? true
    }
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

public struct SearchResponse: Codable, Hashable, Sendable {
    /// What the bot searched for; nil for word search.
    public var explanation: String?
    public var results: [MessageSummary]
}

public struct MessageInsights: Codable, Hashable, Sendable {
    public struct Reply: Codable, Hashable, Sendable {
        public var label: String
        public var body: String
    }

    public var summary: String?
    public var replies: [Reply]
}
