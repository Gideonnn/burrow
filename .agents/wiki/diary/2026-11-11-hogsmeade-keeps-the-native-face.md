---
id: 2026-11-11-hogsmeade-keeps-the-native-face
date: 2026-11-11
kind: decision
area: [hogsmeade, hedwig]
topics: [hogsmeade, outings]
---

# Hogsmeade keeps the native face and takes over Evenementen

The household picked the native face of Hogsmeade. Hogsmeade Feest (its target, icon,
scripts, designs, stickers, confetti and the model's celebration state) is gone, and
Hedwig's Evenementen page leaves Hedwig, so Hogsmeade is the only Mac app for outings.

The native face went through a HIG pass: `List(selection:)` over a `Place` enum instead
of plain buttons with a purple row background, `.searchable` in the toolbar, a
`NavigationStack` in the detail column for back and forward, system backgrounds and text
styles, checkboxes and toggle buttons instead of plain buttons with drawn circles and
capsules, and the map as a button with a link pointer instead of `NSCursor` push and pop.

Ported from Hedwig: the edit sheet (as a grouped `Form`, saving a patch of what changed),
notes, the picture picker, a ticket holder by any name, the linked mails, search words,
the history line and the local reminders. New: a linked mail can be read (as plain text)
and moved to another outing or let go.

Rejected:

- **Merging two outings on the client.** No server route exists; moving tickets would mean
  downloading and uploading each file, and a failure half-way leaves two half outings.
  It waits for a server merge in `TODO.md`.
- **Opening a linked mail in Hedwig.** Hedwig has no URL scheme and its control service
  only opens a mail from its current list. The mail shows as text in a sheet instead.
- **Picture framing (dragging the picture in the header).** Hedwig had it; it is a custom
  gesture surface, and the poster fills or fits by itself well enough.

Traps: the secrets hook refuses a Bash command containing `\.key` (a Swift key path such
as `id: \.key`); write such files with the Write tool. `.searchFocused` and
`presentationSizing` need macOS 15 and `pointerStyle` 15 too, so they sit behind
`#available` while the app stays on macOS 14.
