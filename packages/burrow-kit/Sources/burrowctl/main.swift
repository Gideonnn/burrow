import BurrowKit
import Foundation

let usage = """
usage: burrowctl <command>
  apps                          the Burrow apps running on this Mac
  <app> commands                what the app can do, with arguments
  <app> <cmd> [args…]           run a command; arguments in the order `commands` lists,
                                or as name=value (e.g. burrowctl hedwig show inbox)
  mcp                           serve every running app's commands as MCP tools on stdio
  runner <command>              this Mac as a runner for Burrow's tasks; see `burrowctl runner`

Every app answers `state`, `tree`, `find`, `press`, `type`, `select`, `settings` and
`commands`. Sending, deleting, logging out and recording wait for the person.

Add it to an agent once:
  claude mcp add burrow-apps -- burrowctl mcp
  codex mcp add burrow-apps -- burrowctl mcp
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { fail(usage) }

switch first {
case "apps":
    let running = ControlSocket.apps().filter { (try? AppControl(app: $0).commands()) != nil }
    print(running.isEmpty ? "no Burrow app is running" : running.joined(separator: "\n"))
case "mcp":
    MCPServer().run()
case "runner":
    RunnerCommand.main(Array(args.dropFirst()))
case "-h", "--help", "help":
    print(usage)
default:
    guard args.count >= 2 else { fail(usage) }
    let control = AppControl(app: first)
    do {
        let reply: Data
        if args[1] == "commands" {
            reply = try control.raw(["cmd": "commands"])
        } else {
            let infos = try control.commands()
            guard let info = infos.first(where: { $0.name == args[1] }) else {
                fail("\(first) has no command \(args[1]); see `burrowctl \(first) commands`")
            }
            reply = try control.raw(AppControl.request(info, Array(args.dropFirst(2))))
        }
        print(String(decoding: reply, as: UTF8.self))
        let ok = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["ok"] as? Bool
        exit(ok == true ? 0 : 1)
    } catch {
        fail(error.localizedDescription, code: 2)
    }
}
