import Foundation

extension ServerEvent {
    public var mailboxId: String? { self["mailboxId"] }
    public var messageId: String? { self["messageId"] }
}

extension TaskResult {
    /// The provider operations a mail task proposes; the shared result only
    /// knows them as JSON.
    public var mailOps: [ServerOp] {
        ops.compactMap { op in
            guard let data = try? JSONEncoder().encode(op) else { return nil }
            return try? JSONDecoder().decode(ServerOp.self, from: data)
        }
    }
}
