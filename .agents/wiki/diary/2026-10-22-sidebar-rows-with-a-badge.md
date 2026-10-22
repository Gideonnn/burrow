# 2026-10-22 Sidebar rows with a badge need a tag

Gideon found that Gefilterd, Evenementen, Taken and Concepten could not be opened from
Hedwig's sidebar, while the mailboxes, Verstuurd, Archief and Spam could. A click
highlighted the row but left `AppModel.selection` alone, so the window kept showing the
previous place under the new highlight.

## Cause

In a `List(selection:)` on macOS, a `NavigationLink(value:)` row that also has
`.badge(...)` no longer reports its value to the selection. The mailbox rows had a
`.tag(SidebarItem...)` as well and worked; the Overal rows with a badge had none, and the
ones without a badge worked by their value alone.

## Decisions

- Every badged row carries `.tag` with the same `SidebarItem` as its link.
- The sidebar's binding ignores `nil`: a place is only ever replaced by another place,
  so a list that clears its selection can no longer leave the window on "every mail"
  (the `default` case of the content switch) under a stale highlight.

## Trap

`hedwigctl show outings` sets the selection in the model and so never showed the bug;
only a real click does. To check the sidebar, click it (a CGEvent from a small Swift
script works) and read `hedwigctl state`.
