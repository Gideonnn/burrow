import Foundation

public enum APIError: Error, Equatable, LocalizedError {
    case unauthorized
    case forbidden(String)
    case notFound
    case server(status: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "De server kent deze sleutel niet (meer)."
        case .forbidden(let m): "Deze sleutel mag dit niet: \(m)"
        case .notFound: "Niet gevonden."
        case .server(let status, let message): "Serverfout \(status): \(message)"
        case .invalidResponse: "Onverwacht antwoord van de server."
        }
    }
}

/// The Burrow server API, authenticated with one API key.
public struct APIClient: Sendable {
    public let baseURL: URL
    let token: String
    let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            if let date = Self.isoFractional.date(from: text) ?? Self.iso.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "bad date \(text)"))
        }
        return decoder
    }()

    nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let iso = ISO8601DateFormatter()

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func call<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: (some Encodable)? = nil as String?) async throws -> T {
        let data = try body.map { try JSONEncoder().encode($0) }
        let (bytes, response) = try await session.data(for: request(method, path, query: query, body: data))
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return try Self.decoder.decode(T.self, from: bytes)
        case 401: throw APIError.unauthorized
        case 403: throw APIError.forbidden(Self.message(bytes))
        case 404: throw APIError.notFound
        default: throw APIError.server(status: http.statusCode, message: Self.message(bytes))
        }
    }

    static func message(_ data: Data) -> String {
        (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            ?? String(data: data, encoding: .utf8) ?? ""
    }

    struct Empty: Decodable {}

    // MARK: Endpoints

    public func me() async throws -> Me { try await call("GET", "api/me") }

    public func messages(mailboxId: String, folder: MailFolder, before: Date? = nil, limit: Int = 100) async throws -> [MessageSummary] {
        var query = [URLQueryItem(name: "folder", value: folder.rawValue), URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: Self.isoFractional.string(from: before))) }
        return try await call("GET", "api/mailboxes/\(mailboxId)/messages", query: query)
    }

    public func updateMailbox(id: String, name: String?, role: MailboxRole?) async throws -> MailboxSummary {
        struct Body: Encodable { var name: String?; var role: MailboxRole? }
        return try await call("PATCH", "api/mailboxes/\(id)", body: Body(name: name, role: role))
    }

    public func sync(mailboxId: String) async throws {
        let _: Empty = try await call("POST", "api/mailboxes/\(mailboxId)/sync")
    }

    public func message(id: String) async throws -> MessageDetail { try await call("GET", "api/messages/\(id)") }

    public func apply(_ ops: [ServerOp], to id: String) async throws -> MessageDetail {
        try await call("POST", "api/messages/\(id)/actions", body: ["ops": ops])
    }

    public func send(_ request: SendRequest) async throws {
        let _: Empty = try await call("POST", "api/send", body: request)
    }

    /// Summary and reply suggestions; the server asks the bot once and caches it.
    public func insights(messageId: String) async throws -> MessageInsights {
        try await call("GET", "api/messages/\(messageId)/insights")
    }

    public func filtered() async throws -> [FilteredEntry] { try await call("GET", "api/filtered") }

    public func confirm(_ ids: [String]) async throws {
        let _: Empty = try await call("POST", "api/filtered/confirm", body: ["ids": ids])
    }

    public func confirmAll() async throws {
        let _: Empty = try await call("POST", "api/filtered/confirm-all")
    }

    public func restore(_ id: String) async throws {
        let _: Empty = try await call("POST", "api/filtered/\(id)/restore")
    }

    public func drafts() async throws -> [Draft] { try await call("GET", "api/drafts") }

    public func deleteDraft(_ id: String) async throws {
        let _: Empty = try await call("DELETE", "api/drafts/\(id)")
    }

    public func instructions() async throws -> String {
        let r: [String: String] = try await call("GET", "api/instructions")
        return r["text"] ?? ""
    }

    public func setInstructions(_ text: String) async throws {
        let _: Empty = try await call("PUT", "api/instructions", body: ["text": text])
    }

    public func rules() async throws -> [LearnedRule] { try await call("GET", "api/rules") }

    public func deleteRule(_ id: String) async throws {
        let _: Empty = try await call("DELETE", "api/rules/\(id)")
    }

    // MARK: Tasks

    public func tasks() async throws -> [TaskItem] { try await call("GET", "api/tasks") }

    public func approve(task id: String) async throws {
        let _: Empty = try await call("POST", "api/tasks/\(id)/approve")
    }

    public func reject(task id: String) async throws {
        let _: Empty = try await call("POST", "api/tasks/\(id)/reject")
    }

    public func claim(runner: String, max: Int = 1) async throws -> [ClaimedTask] {
        try await call("POST", "api/runner/claim", body: ClaimBody(runner: runner, max: max))
    }

    /// Posts the agent's raw JSON answer; the server validates it.
    public func complete(task id: String, answer: Data) async throws {
        var request = request("POST", "api/runner/tasks/\(id)/complete", body: answer)
        request.timeoutInterval = 60
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: Self.message(data))
        }
    }

    public func fail(task id: String, error: String) async throws {
        let _: Empty = try await call("POST", "api/runner/tasks/\(id)/fail", body: ["error": error])
    }

    struct ClaimBody: Encodable { var runner: String; var max: Int }

    public func people() async throws -> [Person] { try await call("GET", "api/admin/people") }

    public func addPerson(name: String) async throws -> Person {
        try await call("POST", "api/admin/people", body: ["name": name])
    }

    public func allMailboxes() async throws -> [MailboxSummary] { try await call("GET", "api/admin/mailboxes") }

    public func keys() async throws -> [ApiKeySummary] { try await call("GET", "api/admin/keys") }

    public func createKey(personId: String, name: String, rights: [Right], mailboxIds: [String]?) async throws -> CreatedKey {
        try await call("POST", "api/admin/keys", body: NewKey(personId: personId, name: name, rights: rights, mailboxIds: mailboxIds))
    }

    public func revokeKey(_ id: String) async throws {
        let _: Empty = try await call("DELETE", "api/admin/keys/\(id)")
    }

    struct NewKey: Encodable { var personId: String; var name: String; var rights: [Right]; var mailboxIds: [String]? }

    /// A one-time link that the browser opens to log in at Google or Microsoft.
    public func connectLink(personId: String, provider: MailProvider) async throws -> URL {
        let r: [String: String] = try await call(
            "POST", "api/admin/accounts/connect", body: ["personId": personId, "provider": provider.rawValue])
        guard let url = r["url"].flatMap(URL.init(string:)) else { throw APIError.invalidResponse }
        return url
    }

    public func addFastmail(personId: String, token: String) async throws {
        let _: Empty = try await call("POST", "api/admin/accounts/fastmail", body: ["personId": personId, "token": token])
    }

    public func eventsRequest() -> URLRequest {
        var r = request("GET", "api/events")
        r.timeoutInterval = 60 * 60 * 24
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return r
    }
}
