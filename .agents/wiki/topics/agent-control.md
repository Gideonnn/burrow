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
`set_setting`, `tasks`, `update`, `restart` and `commands`. Hedwig adds `show`, `open` and
`draft` (prepares a draft and shows it under Concepten); Pensieve adds `show`, `search`,
`open`, `rename`, `redo`, `share`, `stop`, `upload` and `mirror`. `hedwigctl` is the old
name of `burrowctl hedwig`.

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
  local settings (Hedwig: `runner`).
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
