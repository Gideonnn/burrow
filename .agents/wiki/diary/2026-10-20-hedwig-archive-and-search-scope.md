---
id: 2026-10-20-hedwig-archive-and-search-scope
date: 2026-10-20
kind: decision
area: [hedwig, server]
topics: [providers]
---

# The whole archive on Dobby, and search in the open place

Gideon compared Hedwig's search with Apple Mail: "hello tv" found 23 messages in Mail
and 2 in Hedwig. The search worked; the mail was missing. The first sync takes only the
last 100 inbox messages (Microsoft: 30 days), so anything older, archived or sent was
never on the server.

## Decided

- **Bring in the whole archive** with a background backfill per mailbox, newest first, a
  page at a time, instead of asking the provider on every search. Local search stays fast
  as you type, search by meaning and the MCP tool see the same mail, and the filters of a
  bot's plan need no translation per provider. Rejected: provider search per query
  (Gmail `q=`, Graph `$search`, JMAP `text`), slower while typing and three query
  languages to keep in step.
- Backfilled mail is marked triaged (old mail is never sorted), sends no events and never
  overwrites a row sync already has.
- **Search follows the sidebar.** With text in the search field, picking another mailbox
  or folder searches there instead of clearing the field, like Mail; a segmented control
  widens it to every mailbox. The open place wins over the bot's plan (folder, role).
  Gefilterd, Taken and Concepten end the search.

## Watch

- Word search is still `LIKE` over every body. A benchmark with 50,000 messages of 6 KB
  took about 300 ms for a word that matches nothing on a MacBook; if it drags on Dobby,
  an FTS5 index is the next step (see TODO).
- The database grows with every HTML body, and the nightly backup with it.
