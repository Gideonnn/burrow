import Foundation

public struct ServerEvent: Equatable, Sendable {
    public var type: String
    public var mailboxId: String?
    public var messageId: String?
}

/// Parses a Server-Sent Events stream line by line ("event:" and "data:"
/// fields, a blank line ends an event).
public struct SSEParser: Sendable {
    private var event = "message"
    private var data = ""

    public init() {}

    public mutating func feed(_ line: String) -> ServerEvent? {
        if line.isEmpty {
            defer { event = "message"; data = "" }
            guard !data.isEmpty else { return nil }
            struct Payload: Decodable { var mailboxId: String?; var messageId: String? }
            let payload = try? JSONDecoder().decode(Payload.self, from: Data(data.utf8))
            return ServerEvent(type: event, mailboxId: payload?.mailboxId, messageId: payload?.messageId)
        }
        if line.hasPrefix("event:") {
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            data += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

extension APIClient {
    /// Live changes for this key's mailboxes. Reconnects with a growing pause
    /// until the task is cancelled.
    public func events() -> AsyncStream<ServerEvent> {
        AsyncStream { continuation in
            let task = Task {
                var pause: UInt64 = 1
                while !Task.isCancelled {
                    do {
                        let (bytes, response) = try await session.bytes(for: eventsRequest())
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.invalidResponse }
                        pause = 1
                        var parser = SSEParser()
                        for try await line in bytes.lines {
                            if let event = parser.feed(line), event.type != "ping" { continuation.yield(event) }
                            // `lines` skips empty lines, so each data line closes its event.
                            if line.hasPrefix("data:"), let event = parser.feed(""), event.type != "ping" {
                                continuation.yield(event)
                            }
                        }
                    } catch {
                        if Task.isCancelled { break }
                    }
                    try? await Task.sleep(nanoseconds: pause * 1_000_000_000)
                    pause = min(pause * 2, 60)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
