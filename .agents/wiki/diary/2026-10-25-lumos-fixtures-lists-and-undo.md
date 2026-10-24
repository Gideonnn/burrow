---
id: 2026-10-25-lumos-fixtures-lists-and-undo
date: 2026-10-25
kind: decision
area: [lumos, server]
topics: [lumos]
---

# 2026-10-25 Lumos: isolated fixtures, private personal lists, undo on the server

The first local slice of Lumos (phases 0 to 2 of `docs/plans/2026-10-25-lumos.md`)
follows the private handoff, with these choices where the code argued otherwise:

- **Personal lists stay private.** The design study shows "Eén van jullie wil dit" in
  the together view, which would show one person's list to the other. Burrow's rule is
  that people never read each other's content, so the row became "Op jouw lijst, nog
  niet samen" with only your own entries, and the scope picker offers Samen and yourself,
  not the other person. Open question for Gideon: a per-person choice to show your list
  to the household.
- **Undo is a change id, not client bookkeeping.** "Yes" clears an earlier "not now", a
  pass takes a title off the list; an undo built from inverse calls on the Mac would
  recreate rows with new ids and dates. Every change records its effects in
  `lumos_changes` and one call reverses them exactly. Rejected: deleting rows (history
  lost), an undo log per Mac (two Macs disagree).
- **Fixture rows carry an origin**, and the config refuses fixtures where a real
  catalogue or a deployed server is. Rejected: real TMDB ids for fixture titles (a list
  entry would turn into a different real title once Seerr is connected).
- **No `lumos.autoRequest` setting and no request, rating or snippet tables yet.** A
  switch that does nothing misleads, and tables are cheap to add in the phase that fills
  them.
- **Routes adapted to the code**: `GET /lumos/lists/:scope` like the `PUT`, a `titles`
  route for the library pages, `POST /lumos/changes/:id/undo`.

Trap: SQLite treats NULLs as distinct in a unique index, so the shared list (no owner)
needs its own partial index. The test that two people adding one title keep one entry
fails without it.
