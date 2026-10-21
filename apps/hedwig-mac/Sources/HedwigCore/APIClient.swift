import Foundation

/// Hedwig's endpoints on the shared API client.
extension APIClient {
    // MARK: Endpoints

    public func me() async throws -> Me { try await call("GET", "api/me") }

    public func messages(mailboxId: String, folder: MailFolder, before: Date? = nil, limit: Int = 100) async throws -> [MessageSummary] {
        var query = [URLQueryItem(name: "folder", value: folder.rawValue), URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: Self.isoFractional.string(from: before))) }
        return try await call("GET", "api/mailboxes/\(mailboxId)/messages", query: query)
    }

    /// Every word must appear. Login codes and other low-priority mail only with `includeLow`.
    public func search(_ query: String, in scope: SearchScope = .everywhere, includeLow: Bool = false, limit: Int = 100) async throws -> SearchResponse {
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))] + scope.queryItems
        if includeLow { items.append(URLQueryItem(name: "includeLow", value: "true")) }
        return try await call("GET", "api/search", query: items)
    }

    /// The bot turns the question into a search; it never reads the mail.
    public func aiSearch(_ question: String, in scope: SearchScope = .everywhere, includeLow: Bool = false) async throws -> SearchResponse {
        struct Body: Encodable {
            var question: String
            var mailboxId: String?
            var role: MailboxRole?
            var folder: MailFolder?
            var includeLow: Bool
        }
        return try await call(
            "POST", "api/search/ai",
            body: Body(question: question, mailboxId: scope.mailboxId, role: scope.role, folder: scope.folder, includeLow: includeLow))
    }

    /// Every mailbox this key sees, in the order the person wants them.
    public func orderMailboxes(_ ids: [String]) async throws {
        let _: Empty = try await call("PUT", "api/mailboxes/order", body: ["ids": ids])
    }

    public func updateMailbox(id: String, name: String?, role: MailboxRole?, instructions: String? = nil) async throws -> MailboxSummary {
        struct Body: Encodable { var name: String?; var role: MailboxRole?; var instructions: String? }
        return try await call("PATCH", "api/mailboxes/\(id)", body: Body(name: name, role: role, instructions: instructions))
    }

    /// Sets the language the person's bots write in; nil returns to the server default.
    public func setLanguage(_ language: String?) async throws {
        struct Body: Encodable {
            var language: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(language, forKey: .language) // null must be sent, not left out
            }
            enum CodingKeys: CodingKey { case language }
        }
        let _: [String: String?] = try await call("PATCH", "api/me", body: Body(language: language))
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

    /// Prepares a draft on the server; it appears under Concepten to review and send.
    public func createDraft(mailboxId: String, to: [Address], cc: [Address] = [], subject: String, body: String, inReplyTo: String?) async throws -> Draft {
        struct Body: Encodable {
            var mailboxId: String
            var to: [Address]
            var cc: [Address]
            var subject: String
            var body: String
            var inReplyTo: String?
        }
        return try await call(
            "POST", "api/drafts",
            body: Body(mailboxId: mailboxId, to: to, cc: cc, subject: subject, body: body, inReplyTo: inReplyTo))
    }

    public func deleteDraft(_ id: String) async throws {
        let _: Empty = try await call("DELETE", "api/drafts/\(id)")
    }

    public func rules() async throws -> [LearnedRule] { try await call("GET", "api/rules") }

    public func deleteRule(_ id: String) async throws {
        let _: Empty = try await call("DELETE", "api/rules/\(id)")
    }

    public func allMailboxes() async throws -> [MailboxSummary] { try await call("GET", "api/admin/mailboxes") }

    /// A one-time link that the browser opens to log in at Google or Microsoft.
    public func connectLink(personId: String, provider: MailProvider) async throws -> URL {
        let r: [String: String] = try await call(
            "POST", "api/admin/accounts/connect", body: ["personId": personId, "provider": provider.rawValue])
        guard let url = r["url"].flatMap(URL.init(string:)) else { throw APIError.invalidResponse }
        return url
    }

    /// The providers this server can connect; OAuth ones only once their app is configured.
    public func connectableProviders() async throws -> [MailProvider] {
        let r: [String: [String]] = try await call("GET", "api/admin/accounts/providers")
        return (r["providers"] ?? []).compactMap(MailProvider.init(rawValue:))
    }

    public func addFastmail(personId: String, token: String) async throws {
        let _: Empty = try await call("POST", "api/admin/accounts/fastmail", body: ["personId": personId, "token": token])
    }

}
