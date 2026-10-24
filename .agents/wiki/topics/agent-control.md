# Operating the apps as an agent

To show the person something in a Burrow app, prepare something in it, or change the
person's settings, use `burrowctl` against the running app, or its MCP server. To search
or read data without an interface, the server's MCP endpoint is the better tool
([MCP](mcp.md)): it searches everything on the server, while an app only shows what is
on screen.

## burrowctl

Installed in `~/.local/bin` by `pnpm hedwig:install` and `pnpm pensieve:install`.

```bash
burrowctl apps                       # running apps
burrowctl hedwig commands            # what an app can do, with arguments
burrowctl hedwig show inbox          # arguments in order, or name=value
burrowctl hedwig draft to=a@example.com subject=Hoi body="Tot morgen"
burrowctl pensieve search offerte
burrowctl pensieve set_setting pensieve.speakers true
```

Every app answers `state`, `tree`, `find`, `press`, `type`, `select`, `settings`,
`set_setting`, `tasks`, `update`, `restart` and `commands`. Hedwig adds `show` (`inbox`,
`archive`, `sent`, `spam` or `drafts` of the open mailbox, or `<place>:<address>`;
`filtered` opens the first Spam or Archief with mail to review), `open` and `draft`
(prepares a draft and shows it under that mailbox's Concepten); Pensieve adds `show` (scope, kind,
labels), `search`, `open`, `rename`, `redo`, `transcribe`, `label`, `mark`, `share`, `stop`,
`upload` and `mirror`; never a start. Lumos adds `show` (page and scope), `search`,
`open` (`movie:9000001`), `trailer`, `stop` and `close`; its list buttons ask the person. `hedwigctl` is the old
name of `burrowctl hedwig`.

## The runner: this Mac doing Burrow's tasks

`burrowctl runner` claims tasks from the server and runs them on this Mac: requests for a
local model (`ollama:<name>`, the local queue with raw mail) through Ollama on
`localhost:11434`, everything else with the local `claude`. A local request never reaches
Claude. It replaces the runner that lived in Hedwig, so it works with every app closed.

```bash
burrowctl runner login [server-url]  # a device key with only read and tasks
burrowctl runner install             # launchd agent app.burrow.runner, starts at login
burrowctl runner on | off            # resume or pause it on the server
burrowctl runner status              # the household's runners and your waiting work
burrowctl runner config              # settings, in the defaults suite app.burrow.runner
burrowctl runner set nightOnly=false concurrency=1
burrowctl runner uninstall
```

- The local queue is only offered inside the night window (`nightStart`, `nightEnd`,
  default 00:00 to 07:00) on the charger (`nightOnly`, `chargerOnly`), and only when
  Ollama has the configured `model` (default `ollama:gemma4:26b-a4b`). The cloud queue is
  offered whenever Claude is found (`claudePath` overrides the search).
- Each claim is the heartbeat, so the server lists the runner as online; pausing is a
  server flag, so the menu, `on`/`off` and Hedwig's Settings › Runners agree.
- While tasks run it holds a sleep assertion. A closed lid without an external display
  still sleeps, so leave the lid open at night.
- `run` is the foreground process launchd starts: the loop plus a menu bar icon (status,
  progress such as "Mail-facts: 12.400 van 48.000", Aan, "Alleen 's nachts aan de
  lader", Lokaal, Cloud, Stoppen). Its log is `~/Library/Logs/burrow-runner.log`.
- The key is read from the Keychain once at start, so a rebuilt binary asks for Keychain
  access while you are there, not at night.

Code: `packages/burrow-kit/Sources/BurrowKit/Runner.swift`, `OllamaAgent.swift`,
`ClaudeCLI.swift` and `Sources/burrowctl/RunnerCommand.swift`.

## As MCP tools

```bash
claude mcp add burrow-apps -- burrowctl mcp
codex mcp add burrow-apps -- burrowctl mcp
```

Every command of every running app becomes a tool `<app>_<command>`; `burrow_apps` and
`burrow_run` cover apps started after the tools were listed.

## Limits, on purpose

- Password and key fields have no value in the tree and refuse `type`; anything an app
  marks `<app>.secret…` is hidden.
- Pressing a button marked `<app>.approve.…` (send, delete, log out, record, share,
  revoke) or labelled Verstuur, Verwijder, Uitloggen or Neem op opens a dialog for the
  person. The call waits up to five minutes; the dialog is not in the tree, so an agent
  cannot approve itself.
- Not possible at all: logging in or out, keys, the server address, starting a
  recording. `set_setting` only reaches settings modules declare and the app's own
  local settings.
- The sockets are `~/Library/Application Support/Burrow/control/<app>.sock`, mode 600:
  any process of the same macOS user can use them. `BURROW_CONTROL_DIR` moves them, for
  a test copy next to the real apps.

## How it works

`packages/burrow-kit/Sources/BurrowKit/Control/` holds the service (policy, ids, JSON,
command catalogue) and the socket; `BurrowUI/AccessibilitySurface.swift` reads the app's
own accessibility tree from inside the process, so no Accessibility permission is
needed; `BurrowUI/AppServices.swift` registers the standard commands.

Traps found while building it:

- SwiftUI builds its accessibility elements only after the app is told an assistive app
  is present: set `AXEnhancedUserInterface` and `AXManualAccessibility` on `NSApp`.
- Its elements (`AccessibilityNode`) answer the Objective-C accessibility getters but do
  not conform to `NSAccessibilityProtocol` in Swift, so the surface calls them by selector.
- Setting `AXSelected` on a list row does nothing; selecting the row in its
  `NSTableView` reaches the SwiftUI selection binding.
- Some buttons report a failed press after pressing; never fall back to a second route.
