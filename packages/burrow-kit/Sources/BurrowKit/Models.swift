import Foundation

public enum Right: String, Codable, Sendable, CaseIterable {
    case read, organize, draft, send, tasks, admin
}

public struct Person: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The person behind the key, as every app sees it (GET /api/me). Modules add
/// their own fields to the same answer, which their apps decode separately.
public struct Profile: Codable, Sendable {
    public struct Key: Codable, Sendable { public var id: String; public var name: String }
    public var person: Person
    public var key: Key
    public var rights: [Right]
    public var language: String?
    // Optional so an older server still decodes.
    public var admin: Bool?
    public var settings: [String: SettingValue]?

    public func can(_ right: Right) -> Bool { rights.contains(right) }
    public var isAdmin: Bool { admin == true && can(.admin) }

    public func enabled(_ setting: String) -> Bool {
        if case .bool(let on) = settings?[setting] { return on }
        return false
    }
}

/// A setting value: on/off, a choice or text, or nothing (the default).
public enum SettingValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
}

/// A setting a module offers; the apps render these without knowing them.
public struct SettingDefinition: Codable, Hashable, Identifiable, Sendable {
    public struct Option: Codable, Hashable, Sendable {
        public var value: String
        public var label: String
    }

    public enum Kind: String, Codable, Sendable { case boolean, choice, text }

    public var key: String
    public var module: String
    public var label: String
    public var description: String?
    public var type: Kind
    public var options: [Option]?
    public var `default`: SettingValue
    public var feature: Bool

    public var id: String { key }
}

public struct ApiKeySummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var personId: String
    public var name: String
    public var prefix: String
    public var rights: [Right]
    public var restrictions: [String: [String]]?
    public var mailboxIds: [String]?
    /// The key reads facts about mail (category, summary, names), never the mail itself.
    public var factsOnly: Bool?
    public var lastUsedAt: Date?
    public var revokedAt: Date?
}

public struct CreatedKey: Codable, Sendable {
    public var key: ApiKeySummary
    public var token: String
}

/// A person as household admins see them: settings and devices, no content.
public struct HouseholdMember: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var email: String?
    public var admin: Bool
    public var settings: [String: SettingValue]
    public var keys: [ApiKeySummary]
}

/// A name and an address, for mail and anything else that reaches people.
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

/// Any JSON value, for the JSON Schema the server sends with a claimed task.
public enum JSONValue: Codable, Hashable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public var string: String? { if case .string(let v) = self { v } else { nil } }
}

/// What a bot's task produced: a summary to read, fields, and for mail tasks
/// operations and a draft that apply after approval.
public struct TaskResult: Codable, Hashable, Sendable {
    public struct DraftProposal: Codable, Hashable, Sendable {
        public var to: [Address]
        public var subject: String
        public var body: String
    }

    public var summary: String
    public var fields: [String: String]
    public var ops: [JSONValue]
    public var draft: DraftProposal?
}

public struct TaskItem: Codable, Hashable, Identifiable, Sendable {
    public struct Subject: Codable, Hashable, Sendable {
        public var type: String
        public var id: String
    }

    public var id: String
    public var kind: String?
    public var title: String?
    public var routineId: String?
    public var routineName: String
    public var skill: String
    public var bot: String
    public var `where`: String
    // Optional so an older server still decodes.
    public var queue: String?
    public var priority: String?
    public var model: String?
    public var status: String
    public var subject: Subject?
    public var messageId: String?
    public var result: TaskResult?
    public var error: String?
    public var claimedBy: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var displayTitle: String { title ?? routineName }
}

public struct AgentRequest: Codable, Hashable, Sendable {
    public var model: String
    public var effort: String?
    public var system: String
    public var prompt: String
    public var schema: JSONValue
    public var agent: String?
    public var timeoutMs: Int?
}

public struct ClaimedTask: Codable, Hashable, Sendable {
    public var task: TaskItem
    public var request: AgentRequest
}

/// What a runner tells the server with each claim; the claim is also its heartbeat.
public struct RunnerOffer: Codable, Hashable, Sendable {
    public var queues: [String]
    public var agents: [String]
    public var models: [String]
    public var concurrency: Int

    public init(queues: [String] = ["cloud"], agents: [String] = ["claude"], models: [String] = [], concurrency: Int = 1) {
        self.queues = queues
        self.agents = agents
        self.models = models
        self.concurrency = concurrency
    }
}

/// A machine that claims and runs tasks: a Mac, or the server's own pool.
public struct RunnerInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var personName: String?
    public var mine: Bool
    public var queues: [String]
    public var agents: [String]
    public var models: [String]
    public var kinds: [String]
    public var paused: Bool
    public var online: Bool
    public var lastSeenAt: Date?
    public var doing: String?
}

/// Work waiting for the key's person, per task kind.
public struct QueueWork: Codable, Hashable, Identifiable, Sendable {
    public var queue: String
    public var kind: String
    public var title: String
    public var waiting: Int
    public var done: Int?
    public var id: String { "\(queue)/\(kind)" }

    /// "Mail-facts: 12.400 van 48.000", or "Mail-facts: 35 te gaan" without a total.
    public var progress: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "nl_NL")
        let n = { (v: Int) in f.string(from: NSNumber(value: v)) ?? String(v) }
        if let done { return "\(title): \(n(done)) van \(n(done + waiting))" }
        return "\(title): \(n(waiting)) te gaan"
    }
}

public struct RunnersResponse: Codable, Hashable, Sendable {
    public var runners: [RunnerInfo]
    public var work: [QueueWork]
}

/// The bots and skills the server knows.
public struct Catalog: Codable, Sendable {
    public struct Bot: Codable, Hashable, Identifiable, Sendable {
        public var name: String
        public var displayName: String
        public var description: String
        public var model: String
        public var agent: String?
        public var skills: [String]
        public var id: String { name }
    }

    public struct Skill: Codable, Hashable, Identifiable, Sendable {
        public var name: String
        public var description: String
        public var id: String { name }
    }

    public var bots: [Bot]
    public var skills: [Skill]
}
