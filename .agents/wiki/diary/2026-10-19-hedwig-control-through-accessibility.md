---
id: 2026-10-19-hedwig-control-through-accessibility
date: 2026-10-19
kind: decision
area: [hedwig]
topics: [hedwig-control]
---

# Hedwig control through its own accessibility tree

Gideon wanted agents to press anything he can press in Hedwig and read its state as
JSON. Built: a socket in the app and `hedwigctl`, with the app walking its own
accessibility tree. Password and key fields are off limits; Verstuur and Verwijder need
his approval in a dialog the agent cannot see (his choice over blocking them outright or
allowing them).

Rejected:

- **A list of named actions in the model.** Exact, but every new button would need an
  entry, and "everything I can click" would drift.
- **The system Accessibility API from the CLI.** Gives the same tree, but needs the
  Accessibility permission for the terminal, which then controls every app on the Mac.
- **Synthesised mouse clicks for rows.** A table tracks the mouse inside `mouseDown`;
  selecting the row in its `NSTableView` turned out simpler and reliable.

Cost: about an hour of probing why SwiftUI showed an empty tree (see the traps in the
topic). It surfaced a real bug: clicking an inbox in the sidebar cleared the selection,
because `ForEach` tagged rows with the mailbox id instead of a `SidebarItem`.
