# Operating Hedwig as an agent

To show the person something in Hedwig, or act in its interface, use `hedwigctl`
against the running app. To search or read mail without the interface, MCP is the
better tool (see [MCP](mcp.md)): it searches every mailbox on the server, while the
interface only shows the current list.

## Commands

`hedwigctl state` returns JSON with the mailboxes, the current list, the selected
message and its plain-text body. `show <place>` (`inbox`, `inbox:<address>`,
`filtered`, `drafts`, `tasks`, `archive`, `sent`, `spam`) and `open <messageId>` wait
until the list or message has loaded. `tree` and `find <text>` give every window, button,
field and menu item with an id; `press`, `type` and `select` act on an id. Ids are paths
in the current tree and change when the interface does, so read the tree again after
anything that changes the screen.

## Limits, on purpose

- Password and key fields have no value in the tree and refuse `type`; a key shown after
  creating it and the button that copies it are hidden or refused.
- `press` on Verstuur or Verwijder (the buttons marked `needsApproval`, including the
  menu item) opens a dialog for the person. The call waits up to five minutes; while the
  dialog is open Hedwig answers nothing else. The dialog is not in the tree, so an agent
  cannot approve itself.
- The socket is `~/Library/Application Support/Hedwig/control.sock`, mode 600: any
  process of the same macOS user can use it. `HEDWIG_CONTROL_SOCKET` moves it, for a test
  copy next to the real app.

## How it works

`apps/hedwig-mac/Sources/HedwigCore/Control/` holds the service (policy, ids, JSON) and
the socket; `Sources/Hedwig/AccessibilitySurface.swift` reads the app's own
accessibility tree from inside the process, so no Accessibility permission is needed.

Traps found while building it:

- SwiftUI builds its accessibility elements only after the app is told an assistive app
  is present: set `AXEnhancedUserInterface` and `AXManualAccessibility` on `NSApp`.
- Its elements (`AccessibilityNode`) answer the Objective-C accessibility getters but do
  not conform to `NSAccessibilityProtocol` in Swift, so the surface calls them by selector.
- Setting `AXSelected` on a list row does nothing; selecting the row in its
  `NSTableView` reaches the SwiftUI selection binding.
- Some buttons report a failed press after pressing; never fall back to a second route.
