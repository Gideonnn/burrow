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

/// Lets an agent on this Mac read and operate Hedwig the way a person does,
/// over newline-delimited JSON: `{"cmd":"tree"}`, `{"cmd":"press","id":"0/3/1"}`.
/// Password and key fields stay unreadable and untypable; sending and deleting
/// wait until the person approves.
@MainActor
public final class ControlService {
    public typealias Command = @MainActor ([String: Any]) async throws -> Any

    private let surface: ControlSurface
    private let state: @MainActor () -> Any
    private let approve: @MainActor (String) async -> Bool
    private var commands: [String: Command] = [:]

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
    public func register(_ name: String, _ command: @escaping Command) {
        commands[name] = command
    }

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

    static func isSecret(_ node: ControlNode) -> Bool {
        node.subrole == "AXSecureTextField"
            || node.identifier?.hasPrefix("hedwig.secret") == true
            || node.value?.range(of: #"bk_[A-Za-z0-9_-]{20,}"#, options: .regularExpression) != nil
    }

    static func needsApproval(_ node: ControlNode) -> Bool {
        ["hedwig.send", "hedwig.trash"].contains(node.identifier ?? "")
            || ["verstuur", "verwijder"].contains(node.label?.lowercased() ?? "")
    }
}
