---
id: 2026-10-23-hedwig-toolbar-measured-against-mail
date: 2026-10-23
kind: trap
area: [hedwig]
topics: []
---

# 2026-10-23 Mail centres its toolbar groups too; Hedwig already matched

Gideon asked for the toolbar above the reading column exactly as Apple Mail on macOS 26
lays it out, assuming Mail does not centre the groups. Window screenshots of Mail and
Hedwig at 1000, 1100, 1300 and 1500 pt, with and without the sidebar, measured in points:

| Window | Mail: compose → first group | Mail: last group → search | Mail search | Hedwig gaps | Hedwig search |
|---|---|---|---|---|---|
| 1500 (Hedwig 1472, the screen's limit) | 125 | 124 | 318 | 188 / 188 | 311 |
| 1300 | 25 | 24 | 318 | 102 / 99 | 314 |
| 1300, no sidebar | 99 | 99 | 311 | | |
| 1100, no sidebar | 22 | 22 | 264 | 64 / 64 | 311 |
| 1000 | 26 | 25 | magnifier | 22 / 22 | 171 |

Mail: compose at the reading column's leading edge, a flexible space, the groups 15 pt
apart (reply, organize, Move menu, Flag), a flexible space, then a search field of about
310 pt that shrinks when space runs out and folds into a magnifier button once less than
somewhere between 175 and 260 pt is left. Both flexible spaces get the same slack, so the groups are centred between
compose and search at every width; with the sidebar hidden compose follows the column.

Hedwig's toolbar from the native-toolbar change does the same, so the layout code stayed.
Mail's groups only look closer to compose because Mail has four of them; Hedwig has two
(flagging is in the menu). Not copied from Mail: the Move and Flag groups, and folding
the search field into a magnifier, which SwiftUI's `.searchable` decides by itself.

Measuring: `CGWindowListCopyWindowInfo` for the window ids, `screencapture -x -o -l<id>`,
and a scan of one pixel row through the toolbar for the capsules' edges. Mail had no
viewer window open; `open -a Mail` makes one, and AppleScript's `bounds` resizes it.
