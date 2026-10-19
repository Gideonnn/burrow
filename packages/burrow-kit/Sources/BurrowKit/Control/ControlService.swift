import Foundation

/// One element of the interface as the accessibility tree reports it. `handle`
/// is whatever the surface needs to act on it again.
public struct ControlNode {
    public var role: String
    public var subrole: String?
    public var identifier: String?
    public var label: String?
    public var value: String?
    public var enabled: Bool
    public var children: [ControlNode]
    public var handle: AnyObject?

    public init(
        role: String, subrole: String? = nil, identifier: String? = nil, label: String? = nil,
        value: String? = nil, enabled: Bool = true, children: [ControlNode] = [], handle: AnyObject? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.label = label
        self.value = value
        self.enabled = enabled
        self.children = children
        self.handle = handle
    }
}

/// The app's windows and menus, readable and operable.
@MainActor
public protocol ControlSurface: AnyObject {
    func snapshot() -> [ControlNode]
    func press(_ node: ControlNode) throws
    func type(_ node: ControlNode, _ text: String) throws
    func select(_ node: ControlNode) throws
}

public struct ControlError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ControlArgument: Sendable {
    public var name: String
    public var help: String

    public init(_ name: String, _ help: String) {
        self.name = name
        self.help = help
    }
}

/// What an app command is for, so `burrowctl` and its MCP tools can explain it.
public struct ControlCommandInfo: Sendable {
    public var name: String
    public var help: String
    // In order: `burrowctl <app> <cmd> a b` fills them positionally.
    public var arguments: [ControlArgument]

    public init(name: String, help: String, arguments: [ControlArgument] = []) {
        self.name = name
        self.help = help
        self.arguments = arguments
    }
}

/// Lets an agent on this Mac read and operate an app the way a person does,
/// over newline-delimited JSON: `{"cmd":"tree"}`, `{"cmd":"press","id":"0/3/1"}`.
/// Password and key fields stay unreadable and untypable; sending, deleting
/// and anything else in `approvalIdentifiers` wait until the person approves.
@MainActor
public final class ControlService {
    public typealias Command = @MainActor ([String: Any]) async throws -> Any

    private let surface: ControlSurface
    private let state: @MainActor () -> Any
    private let approve: @MainActor (String) async -> Bool
    private var commands: [String: Command] = [:]
    private var infos: [String: ControlCommandInfo] = [:]

    public init(
        surface: ControlSurface,
        state: @escaping @MainActor () -> Any,
        approve: @escaping @MainActor (String) async -> Bool
    ) {
        self.surface = surface
        self.state = state
        self.approve = approve
    }

    /// Adds an app-level command, such as opening a message by id.
    public func register(_ name: String, help: String = "", arguments: [ControlArgument] = [], _ command: @escaping Command) {
        commands[name] = command
        infos[name] = ControlCommandInfo(name: name, help: help, arguments: arguments)
    }

    /// Every command with its help, the built-in ones first.
    public var catalog: [ControlCommandInfo] {
        Self.builtIn + infos.values.sorted { $0.name < $1.name }
    }

    static let builtIn: [ControlCommandInfo] = [
        .init(name: "state", help: "What the app shows right now, as JSON."),
        .init(name: "tree", help: "Every window, button, field and menu item, with ids."),
        .init(name: "find", help: "Elements whose label, identifier or value contains the text.", arguments: [.init("text", "what to look for")]),
        .init(name: "press", help: "Press a button or menu item; sending and deleting ask the person.", arguments: [.init("id", "an id from tree or find")]),
        .init(name: "type", help: "Type into a text field; password and key fields are refused.", arguments: [.init("id", "an id from tree or find"), .init("text", "what to type")]),
        .init(name: "select", help: "Select a row.", arguments: [.init("id", "an id from tree or find")]),
    ]

    public func handle(_ data: Data) async -> Data {
        let reply: [String: Any]
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = request["cmd"] as? String
            else { throw ControlError("send a JSON object with a cmd") }
            reply = ["ok": true, "result": try await run(cmd, request)]
        } catch {
            reply = ["ok": false, "error": error.localizedDescription]
        }
        return (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data(#"{"ok":false}"#.utf8)
    }

    private func run(_ cmd: String, _ request: [String: Any]) async throws -> Any {
        switch cmd {
        case "commands":
            return catalog.map { info in
                [
                    "name": info.name, "help": info.help,
                    "arguments": info.arguments.map { ["name": $0.name, "help": $0.help] },
                ] as [String: Any]
            }
        case "state":
            return state()
        case "tree":
            return surface.snapshot().enumerated().map { describe($1, id: "\($0)", deep: true) }
        case "find":
            let text = (request["text"] as? String ?? "").lowercased()
            var matches: [[String: Any]] = []
            walk(surface.snapshot()) { node, id in
                let haystack = [node.label, node.identifier, Self.isSecret(node) ? nil : node.value]
                if haystack.contains(where: { $0?.lowercased().contains(text) == true }) {
                    matches.append(describe(node, id: id, deep: false))
                }
            }
            return matches
        case "press":
            let node = try resolve(request)
            if Self.isSecret(node) { throw ControlError("this element shows or copies a secret") }
            if Self.needsApproval(node), await !approve(node.label ?? node.identifier ?? node.role) {
                throw ControlError("the person declined")
            }
            try surface.press(node)
            return "pressed"
        case "type":
            let node = try resolve(request)
            if Self.isSecret(node) { throw ControlError("password and key fields are off limits") }
            try surface.type(node, request["text"] as? String ?? "")
            return "typed"
        case "select":
            try surface.select(try resolve(request))
            return "selected"
        default:
            guard let command = commands[cmd] else { throw ControlError("unknown cmd \(cmd)") }
            return try await command(request)
        }
    }

    private func resolve(_ request: [String: Any]) throws -> ControlNode {
        guard let id = request["id"] as? String else { throw ControlError("missing id") }
        var nodes = surface.snapshot()
        var found: ControlNode?
        for part in id.split(separator: "/") {
            guard let index = Int(part), nodes.indices.contains(index) else {
                found = nil
                break
            }
            found = nodes[index]
            nodes = nodes[index].children
        }
        guard let found else {
            throw ControlError("no element \(id); the interface may have changed, read the tree again")
        }
        return found
    }

    private func walk(_ nodes: [ControlNode], prefix: String? = nil, _ visit: (ControlNode, String) -> Void) {
        for (index, node) in nodes.enumerated() {
            let id = prefix.map { "\($0)/\(index)" } ?? "\(index)"
            visit(node, id)
            walk(node.children, prefix: id, visit)
        }
    }

    private func describe(_ node: ControlNode, id: String, deep: Bool) -> [String: Any] {
        var out: [String: Any] = ["id": id, "role": node.role]
        if let subrole = node.subrole { out["subrole"] = subrole }
        if let identifier = node.identifier { out["identifier"] = identifier }
        if let label = node.label, !label.isEmpty { out["label"] = label }
        if Self.isSecret(node) {
            out["secret"] = true
        } else if let value = node.value, !value.isEmpty {
            out["value"] = value
        }
        if !node.enabled { out["enabled"] = false }
        if Self.needsApproval(node) { out["needsApproval"] = true }
        if deep, !node.children.isEmpty {
            out["children"] = node.children.enumerated().map { describe($1, id: "\(id)/\($0)", deep: true) }
        }
        return out
    }

    /// Secure fields, anything an app marks `<app>.secret…`, and API keys.
    static func isSecret(_ node: ControlNode) -> Bool {
        node.subrole == "AXSecureTextField"
            || node.identifier?.contains(".secret") == true
            || node.value?.range(of: #"bk_[A-Za-z0-9_-]{20,}"#, options: .regularExpression) != nil
    }

    /// Sending, deleting, logging out and recording are for the person: an app
    /// marks such buttons `<app>.approve.…`; the older Hedwig ids still count.
    static func needsApproval(_ node: ControlNode) -> Bool {
        let id = node.identifier ?? ""
        return id.contains(".approve.") || ["hedwig.send", "hedwig.trash"].contains(id)
            || ["verstuur", "verwijder", "uitloggen", "neem op"].contains(node.label?.lowercased() ?? "")
    }
}
