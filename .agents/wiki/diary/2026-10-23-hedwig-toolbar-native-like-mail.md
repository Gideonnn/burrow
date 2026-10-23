---
id: 2026-10-23-hedwig-toolbar-native-like-mail
date: 2026-10-23
kind: trap
area: [hedwig]
topics: []
---

# Hedwig's toolbar native, like Apple Mail

Gideon compared Hedwig with Mail on macOS 26: Hedwig's icons were heavier, compose sat
next to the reply group instead of at the left of the reading column, and the groups did
not dim in an inactive window. The cause was custom styling: borderless buttons with
`.imageScale(.large)` inside hand-made `glassEffect` capsules. Plain `ToolbarItem`s with a
`ControlGroup` (`.controlGroupStyle(.navigation)`) give Mail's capsules with separators,
symbol size, per-segment tooltips and inactive dimming for free.

Traps:

- A three-column `NavigationSplitView` only gets an `NSTrackingSeparatorToolbarItem` for
  the list/reading divider when the list column has a toolbar item of its own. Without
  it every item after the title sits in one section and the title's slack lands in front
  of compose. A `ToolbarSpacer` on the list column is enough.
- `ToolbarSpacer(.fixed)` does keep two groups in separate glass; the older note that
  macOS 26 merges across spacers no longer holds with native items.
- `.principal` becomes `NSToolbar.centeredItemIdentifiers`, centred on the window, and
  pushed compose behind the groups. Rejected.
- SwiftUI adds a flexible space before the search field, so one `ToolbarSpacer(.flexible)`
  after compose centres the groups between compose and the search field. That is exactly
  Mail's own layout, not a compromise: centring on the column was never Mail's behaviour
  (see [the measurement](2026-10-23-hedwig-toolbar-measured-against-mail.md)).
