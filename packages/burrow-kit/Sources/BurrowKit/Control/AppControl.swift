import Foundation

/// The other end of an app's control socket, for `burrowctl` and tests.
public struct AppControl: Sendable {
    public struct Command: Decodable, Sendable {
        public struct Argument: Decodable, Sendable {
            public var name: String
            public var help: String
        }

        public var name: String
        public var help: String
        public var arguments: [Argument]
    }

    public let app: String
    let client: ControlSocketClient

    public init(app: String) {
        self.app = app
        self.client = ControlSocketClient(app: app)
    }

    public func raw(_ request: [String: Any]) throws -> Data {
        try client.send(try JSONSerialization.data(withJSONObject: request))
    }

    public func commands() throws -> [Command] {
        struct Reply: Decodable { var ok: Bool; var result: [Command]? }
        let reply = try JSONDecoder().decode(Reply.self, from: try raw(["cmd": "commands"]))
        guard reply.ok, let result = reply.result else { throw ControlError("\(app) did not list its commands") }
        return result
    }

    /// Builds a request from `name=value` pairs or values in argument order;
    /// extra positional words join into the last argument ("show inbox:a@b").
    public static func request(_ command: Command, _ words: [String]) -> [String: Any] {
        var request: [String: Any] = ["cmd": command.name]
        var positional: [String] = []
        for word in words where word != "--force" {
            if let eq = word.firstIndex(of: "="), command.arguments.contains(where: { $0.name == String(word[..<eq]) }) {
                request[String(word[..<eq])] = String(word[word.index(after: eq)...])
            } else {
                positional.append(word)
            }
        }
        let open = command.arguments.filter { request[$0.name] == nil }
        for (index, argument) in open.enumerated() where index < positional.count {
            request[argument.name] = index == open.count - 1
                ? positional[index...].joined(separator: " ")
                : positional[index]
        }
        if words.contains("--force") { request["force"] = true }
        return request
    }
}
