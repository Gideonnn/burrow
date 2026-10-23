---
id: 2026-10-23-hedwig-typography-measured-against-mail
date: 2026-10-23
kind: decision
area: [hedwig]
topics: []
---

# Hedwig's typography measured against Apple Mail

Gideon asked for Mail's font sizes and styling wherever Hedwig has the same element, without
copying Mail's features. Both windows were captured at the same size with
`screencapture -l<window id>` and compared in pixels (glyph heights, widths and total ink of
the same strings), not by eye. Where the strings were identical, ink and width matched to
within a pixel after the change.

## What Mail uses (macOS 26, defaults)

`osascript -e 'tell application "Mail" to get {message font, message font size, message list font size}'`
reads Mail's font settings; its preferences plist is sandboxed and `defaults read` fails.
The defaults are Helvetica 12 for messages and the system font at 11 for the list.

- **List:** sender 13 pt semibold (not bold), subject, preview and date 11 pt, 3 pt between
  lines, 80 pt rows. Dates: "06:54", "Gisteren", then "20-10-2026"; no weekday names.
- **Reader header:** sized from the 12 pt message font: 32 pt avatar, sender 14 pt
  semibold, subject and Aan/Kopie 12 pt (labels regular in the primary colour, names grey),
  date 11 pt as "06:54", "Gisteren om 17:06" or "3 september 2026 om 22:01". Header and
  divider 28 pt from the column edges.
- **Sidebar:** the same 13 pt rows and icon tint as SwiftUI's sidebar list; counts 11 pt
  semibold; section headers in secondary grey.
- **Toolbar:** already identical since the native toolbar change.

The earlier reader entry chose a 44 pt avatar and a 15 pt bold sender by eye; both were too
large.

## Traps

- SwiftUI's `.badge` in a sidebar is 11 pt but lighter than Mail's counts, and cannot be
  restyled. Every sidebar count is now a `SidebarCount` text; the rows keep their tags.
- SwiftUI draws sidebar section headers in tertiary grey. A custom header with
  `.foregroundStyle(.secondary)` matched Mail's grey exactly in light and dark mode.
- `DateFormatter.doesRelativeDateFormatting` compares with the real clock, so "Gisteren" is
  computed by hand in `MailFormat`, which tests can give a fixed `now`.
- The HTML wrapper forced `line-height: 1.5` and 14 px on every mail that sets no style;
  Mail uses normal line height and its message font. It is now `12px Helvetica`.

## Not matched

- Mail darkens light HTML mail in dark mode ("dark backgrounds for messages"); Hedwig shows
  the mail's own colours. That is a feature, not styling.
- Mail's mailbox glyphs are its own images, flatter and smaller on nested rows than the SF
  Symbols Hedwig uses; Mail's section headers also sit 4 pt further right than SwiftUI's.
- Mail shows brand logos or grey initials; Hedwig keeps its coloured initials.
