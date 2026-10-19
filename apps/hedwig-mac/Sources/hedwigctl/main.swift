import Foundation
import HedwigCore

let usage = """
usage: hedwigctl <command>
  state                 what Hedwig shows: mailboxes, the message list, the open message
  tree                  every window, button, field and menu item, with ids
  find <text>           elements whose label, identifier or value contains the text
  press <id>            press a button or menu item; sending and deleting ask the person
  type <id> <text>      type into a text field; password and key fields are refused
  select <id>           select a row
  show <place>          inbox, inbox:<address>, filtered, drafts, tasks, archive, sent, spam
  open <messageId>      open a message from the current list
  update                look for a newer signed build and get it ready
  restart [--force]     quit and start again, installing a ready update; refuses
                        while a message is being written unless --force

Ids come from tree or find and change when the interface does.
"""

let args = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

guard let cmd = args.first else { fail(usage) }
var request: [String: Any] = ["cmd": cmd]
switch (cmd, args.count) {
case ("state", 1), ("tree", 1), ("update", 1), ("restart", 1): break
case ("restart", 2) where args[1] == "--force": request = ["cmd": "restart", "force": true]
case ("find", 2...), ("show", 2...): request["text"] = args.dropFirst().joined(separator: " ")
case ("press", 2), ("select", 2), ("open", 2): request["id"] = args[1]
case ("type", 3...):
    request["id"] = args[1]
    request["text"] = args.dropFirst(2).joined(separator: " ")
default: fail(usage)
}

do {
    let reply = try ControlSocketClient().send(try JSONSerialization.data(withJSONObject: request))
    print(String(decoding: reply, as: UTF8.self))
    let ok = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["ok"] as? Bool
    exit(ok == true ? 0 : 1)
} catch {
    fail(error.localizedDescription, code: 2)
}
