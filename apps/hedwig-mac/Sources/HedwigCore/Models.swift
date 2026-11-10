import Foundation

// Swift mirrors of packages/contracts. Field names match the JSON exactly.

public enum MailProvider: String, Codable, Sendable {
    case gmail, microsoft, fastmail
}

public enum MailFolder: String, Codable, Sendable, CaseIterable {
    case inbox, archive, spam, trash, sent
}

/// What a mailbox is for; the sidebar groups by it.
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
    /// The provider refused the stored login; the owner has to log in again.
    public var needsReconnect: Bool?

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

/// What the server knows about a message without reading it again: the
/// rules, a template or a model derived it, so it is as untrusted as the mail.
public struct MessageFacts: Codable, Hashable, Sendable {
    public struct Amount: Codable, Hashable, Sendable {
        public var value: Double
        public var currency: String
    }

    public var category: String?
    public var priority: String?
    public var summary: String?
    public var sensitive: Bool
    public var sensitiveKinds: [String]?
    public var people: [String]?
    public var organisations: [String]?
    public var keywords: [String]?
    public var dates: [String]?
    public var amounts: [Amount]?
    public var source: String?

    /// The category as a tag; nil for "other" or none.
    public var categoryTitle: String? {
        switch category {
        case "personal": "Persoonlijk"
        case "work": "Werk"
        case "school": "School"
        case "order": "Bestelling"
        case "shipping": "Bezorging"
        case "invoice": "Factuur"
        case "bank": "Bank"
        case "travel": "Reis"
        case "appointment": "Afspraak"
        case "government": "Overheid"
        case "health": "Gezondheid"
        case "newsletter": "Nieuwsbrief"
        case "promotion": "Reclame"
        case "notification": "Melding"
        case "account": "Account"
        case "code": "Code"
        default: nil
        }
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
    // Optional so an older server still decodes.
    public var facts: MessageFacts?
    /// Where a search result matched; only in search results.
    public var hit: SearchHit?
    public var share: MessageShare?
    public var shareSuggestion: ShareSuggestionNote?
}

/// Who sees a message besides its owner; `by` is the owner when it is someone else's.
public struct MessageShare: Codable, Hashable, Sendable {
    public var by: String?
    public var with: [String]

    public init(by: String? = nil, with: [String] = []) {
        self.by = by
        self.with = with
    }
}

/// Winky thinks the household should see this mail.
public struct ShareSuggestionNote: Codable, Hashable, Sendable {
    public var reason: String
}

public struct SharedResponse: Codable, Sendable {
    public var withMe: [MessageSummary]
    public var byMe: [MessageSummary]
}

public struct ShareSuggestionsResponse: Codable, Sendable {
    public struct Suggestion: Codable, Sendable {
        public var message: MessageSummary
        public var reason: String
    }
    public var suggestions: [Suggestion]
}

/// How much mail one folder of a mailbox holds; the server leaves out empty folders.
public struct FolderCount: Codable, Hashable, Sendable {
    public var mailboxId: String
    public var folder: MailFolder
    public var total: Int
    public var unread: Int
}

public struct MessageDetail: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var mailboxId: String
    public var threadId: String?
    public var from: Address
    public var to: [Address]
    public var cc: [Address]
    // Absent from servers older than Reply-To support.
    public var replyTo: [Address]?
    // Whom Reply and Reply all address; the server decides so every client agrees.
    public var reply: Recipients?
    public var replyAll: Recipients?
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
    public var facts: MessageFacts?
    public var share: MessageShare?
    public var shareSuggestion: ShareSuggestionNote?

    /// Remote images tell the sender the mail was opened; in Spam they stay off,
    /// with no offer, until the person says it is not spam.
    public var mayLoadRemoteImages: Bool { folder != .spam }

    public var summary: MessageSummary {
        MessageSummary(
            id: id, mailboxId: mailboxId, threadId: threadId, from: from, to: to, subject: subject,
            snippet: snippet, receivedAt: receivedAt, folder: folder, unread: unread, flagged: flagged,
            labels: labels, hasAttachments: hasAttachments, facts: facts, share: share,
            shareSuggestion: shareSuggestion)
    }
}

public struct Recipients: Codable, Hashable, Sendable {
    public var to: [Address]
    public var cc: [Address]
}

/// A file on a message; the server fetches it from the provider when asked.
public struct Attachment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var contentType: String
    public var size: Int
    public var inline: Bool
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

/// Where a search looks; empty means every mailbox the key sees.
public struct SearchScope: Encodable, Hashable, Sendable {
    public var mailboxId: String?
    public var folder: MailFolder?

    public static let everywhere = SearchScope()

    public var queryItems: [URLQueryItem] {
        [("mailboxId", mailboxId), ("folder", folder?.rawValue)]
            .compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
    }
}

public struct SearchResponse: Codable, Hashable, Sendable {
    /// What the bot searched for; nil for word search.
    public var explanation: String?
    public var results: [MessageSummary]
    /// Every match, beyond the results returned; optional for older servers.
    public var total: Int?
    /// The bot's plan as chips, and the plan itself to rerun without one.
    public var tokens: [SearchToken]?
    public var wantsAnswer: Bool?
    public var plan: JSONValue?
    /// No mail had every word; these have the most of them.
    public var loose: Bool?
}

public struct MessageInsights: Codable, Hashable, Sendable {
    public struct Reply: Codable, Hashable, Sendable {
        public var label: String
        public var body: String
    }

    public var summary: String?
    public var replies: [Reply]
}
