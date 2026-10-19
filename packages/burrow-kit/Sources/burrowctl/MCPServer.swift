import BurrowKit
import Foundation

/// A minimal MCP server over stdio (newline-delimited JSON-RPC 2.0): every
/// command of every running Burrow app becomes a tool named `<app>_<command>`,
/// plus `burrow_apps` and `burrow_run` for apps started later. Each call goes
/// to the app's control socket, so the app's own rules apply: secrets stay
/// hidden and sending, deleting, logging out and recording ask the person.
struct MCPServer {
    func run() {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Notifications have no id and get no answer.
            guard let id = message["id"] else { continue }
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            let reply: [String: Any]
            switch method {
            case "initialize":
                reply = result(id, [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "burrow-apps", "version": "1"],
                    "instructions": """
                    Operate the Burrow apps running on this Mac (Hedwig for mail, Pensieve for \
                    recordings): read what they show, open things, prepare drafts and show them, \
                    change the person's own settings. Start with <app>_state. Sending, deleting, \
                    logging out and recording are the person's: those calls wait for their approval.
                    """,
                ])
            case "tools/list":
                reply = result(id, ["tools": tools()])
            case "tools/call":
                reply = result(id, call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:]))
            case "ping":
                reply = result(id, [:])
            default:
                reply = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "unknown method \(method)"]]
            }
            if let out = try? JSONSerialization.data(withJSONObject: reply) {
                FileHandle.standardOutput.write(out + Data("\n".utf8))
            }
        }
    }

    private func result(_ id: Any, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    private func tools() -> [[String: Any]] {
        var tools: [[String: Any]] = [
            [
                "name": "burrow_apps",
                "description": "The Burrow apps running on this Mac.",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
            [
                "name": "burrow_run",
                "description": "Run any command of a running app, e.g. one started after the tools were listed.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app": ["type": "string"],
                        "command": ["type": "string"],
                        "arguments": ["type": "object", "additionalProperties": ["type": "string"]],
                    ],
                    "required": ["app", "command"],
                ],
            ],
        ]
        for app in ControlSocket.apps() {
            guard let commands = try? AppControl(app: app).commands() else { continue }
            for command in commands {
                tools.append([
                    "name": "\(app)_\(command.name)",
                    "description": "\(command.help) (\(app.capitalized))",
                    "inputSchema": [
                        "type": "object",
                        "properties": Dictionary(uniqueKeysWithValues: command.arguments.map {
                            ($0.name, ["type": "string", "description": $0.help])
                        }),
                        "required": command.arguments.map(\.name),
                    ],
                ])
            }
        }
        return tools
    }

    private func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let text: (String, Bool) -> [String: Any] = { body, error in
            ["content": [["type": "text", "text": body]], "isError": error]
        }
        if name == "burrow_apps" {
            let running = ControlSocket.apps().filter { (try? AppControl(app: $0).commands()) != nil }
            return text(running.joined(separator: "\n"), false)
        }
        var app: String
        var request: [String: Any]
        if name == "burrow_run" {
            app = arguments["app"] as? String ?? ""
            request = (arguments["arguments"] as? [String: Any]) ?? [:]
            request["cmd"] = arguments["command"] as? String ?? ""
        } else {
            guard let underscore = name.firstIndex(of: "_") else { return text("unknown tool \(name)", true) }
            app = String(name[..<underscore])
            request = arguments
            request["cmd"] = String(name[name.index(after: underscore)...])
        }
        do {
            let reply = try AppControl(app: app).raw(request)
            let ok = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["ok"] as? Bool ?? false
            return text(String(decoding: reply, as: UTF8.self), !ok)
        } catch {
            return text(error.localizedDescription, true)
        }
    }
}
