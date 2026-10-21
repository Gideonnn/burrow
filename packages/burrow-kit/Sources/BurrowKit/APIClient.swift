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

/// The Burrow server API, authenticated with one API key. Apps add their
/// module's endpoints in extensions; the platform's own live here.
public struct APIClient: Sendable {
    public let baseURL: URL
    let token: String
    public let session: URLSession

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

    nonisolated(unsafe) public static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let iso = ISO8601DateFormatter()

    public func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
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

    public func call<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: (some Encodable)? = nil as String?) async throws -> T {
        let data = try body.map { try JSONEncoder().encode($0) }
        return try await send(request(method, path, query: query, body: data))
    }

    public func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (bytes, response) = try await session.data(for: request)
        try Self.check(response, bytes)
        // A 204 has no body at all.
        if bytes.isEmpty, let empty = Empty() as? T { return empty }
        return try Self.decoder.decode(T.self, from: bytes)
    }

    public static func check(_ response: URLResponse, _ bytes: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw APIError.unauthorized
        case 403: throw APIError.forbidden(message(bytes))
        case 404: throw APIError.notFound
        default: throw APIError.server(status: http.statusCode, message: message(bytes))
        }
    }

    public static func message(_ data: Data) -> String {
        (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            ?? String(data: data, encoding: .utf8) ?? ""
    }

    public struct Empty: Decodable {
        public init() {}
    }

    // MARK: The person and the household

    public func profile() async throws -> Profile { try await call("GET", "api/me") }

    public func settingsSchema() async throws -> [SettingDefinition] { try await call("GET", "api/settings/schema") }

    public func settings() async throws -> [String: SettingValue] { try await call("GET", "api/me/settings") }

    /// Changes the key's own settings; `.null` resets one to its default.
    public func updateSettings(_ values: [String: SettingValue]) async throws -> [String: SettingValue] {
        try await call("PATCH", "api/me/settings", body: ["values": values])
    }

    public func instructions() async throws -> String {
        let r: [String: String] = try await call("GET", "api/instructions")
        return r["text"] ?? ""
    }

    public func setInstructions(_ text: String) async throws {
        let _: Empty = try await call("PUT", "api/instructions", body: ["text": text])
    }

    /// Everyone in the household, by name; for sharing.
    public func people() async throws -> [Person] { try await call("GET", "api/people") }

    /// Admins: everyone with their settings and devices, never their content.
    public func household() async throws -> [HouseholdMember] { try await call("GET", "api/admin/people") }

    public func updateSettings(of personId: String, _ values: [String: SettingValue]) async throws -> [String: SettingValue] {
        try await call("PATCH", "api/admin/people/\(personId)/settings", body: ["values": values])
    }

    public func instructions(of personId: String) async throws -> String {
        let r: [String: String] = try await call("GET", "api/admin/people/\(personId)/instructions")
        return r["text"] ?? ""
    }

    public func setInstructions(of personId: String, _ text: String) async throws {
        let _: Empty = try await call("PUT", "api/admin/people/\(personId)/instructions", body: ["text": text])
    }

    public func addPerson(name: String) async throws -> Person {
        try await call("POST", "api/admin/people", body: ["name": name])
    }

    public func keys() async throws -> [ApiKeySummary] { try await call("GET", "api/admin/keys") }

    public func createKey(personId: String, name: String, rights: [Right], mailboxIds: [String]?, factsOnly: Bool = false) async throws -> CreatedKey {
        try await call(
            "POST", "api/admin/keys",
            body: NewKey(personId: personId, name: name, rights: rights, mailboxIds: mailboxIds, factsOnly: factsOnly))
    }

    public func revokeKey(_ id: String) async throws {
        let _: Empty = try await call("DELETE", "api/admin/keys/\(id)")
    }

    struct NewKey: Encodable { var personId: String; var name: String; var rights: [Right]; var mailboxIds: [String]?; var factsOnly: Bool }

    // MARK: Bots and tasks

    public func catalog() async throws -> Catalog { try await call("GET", "api/catalog") }

    public func tasks(kind: String? = nil) async throws -> [TaskItem] {
        try await call("GET", "api/tasks", query: kind.map { [URLQueryItem(name: "kind", value: $0)] } ?? [])
    }

    public func approve(task id: String) async throws {
        let _: Empty = try await call("POST", "api/tasks/\(id)/approve")
    }

    public func reject(task id: String) async throws {
        let _: Empty = try await call("POST", "api/tasks/\(id)/reject")
    }

    public func retry(task id: String) async throws {
        let _: Empty = try await call("POST", "api/tasks/\(id)/retry")
    }

    public func claim(runner: String, kinds: [String] = ["routine"], offer: RunnerOffer = RunnerOffer(), max: Int = 1) async throws -> [ClaimedTask] {
        try await call(
            "POST", "api/runner/claim",
            body: ClaimBody(
                runner: runner, max: max, kinds: kinds, queues: offer.queues, agents: offer.agents,
                models: offer.models, concurrency: offer.concurrency))
    }

    public func runners() async throws -> RunnersResponse { try await call("GET", "api/runners") }

    @discardableResult
    public func setRunner(id: String, paused: Bool) async throws -> RunnerInfo {
        try await call("PATCH", "api/runners/\(id)", body: ["paused": paused])
    }

    public func deleteRunner(id: String) async throws {
        let _: Empty = try await call("DELETE", "api/runners/\(id)")
    }

    /// Posts the agent's raw JSON answer; the server validates it.
    public func complete(task id: String, answer: Data) async throws {
        var request = request("POST", "api/runner/tasks/\(id)/complete", body: answer)
        request.timeoutInterval = 60
        let _: Empty = try await send(request)
    }

    public func fail(task id: String, error: String) async throws {
        let _: Empty = try await call("POST", "api/runner/tasks/\(id)/fail", body: ["error": error])
    }

    struct ClaimBody: Encodable {
        var runner: String
        var max: Int
        var kinds: [String]
        var queues: [String]
        var agents: [String]
        var models: [String]
        var concurrency: Int
    }

    public func eventsRequest() -> URLRequest {
        var r = request("GET", "api/events")
        r.timeoutInterval = 60 * 60 * 24
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return r
    }
}
