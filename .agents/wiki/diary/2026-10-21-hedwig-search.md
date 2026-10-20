---
id: 2026-10-21-hedwig-search
date: 2026-10-21
kind: decision
area: [hedwig, server, skills]
topics: [mcp]
---

# Search in Hedwig: words as you type, meaning on Enter

Hedwig's search field searches every mailbox the key sees. Typing runs a word search
(`GET /api/search`, every word must appear in subject, sender, recipients or body);
Enter asks Kreacher (`POST /api/search/ai`, skill `mail-search`) to turn the question
into a plan: groups of alternative words plus filters (sender, period, folder, mailbox
role). The server runs the plan and ranks mail that matches more groups, and subject
hits, higher. The MCP tool `search_messages` uses the same word search.

## Decided

- **The bot sees only the question and the mailbox list, never mail.** No untrusted text
  reaches the agent, so a message cannot steer the search, and one agent run is enough.
  Rejected: letting the bot rank candidate messages (a second, slower run that reads
  untrusted mail) and embeddings (an extra API and an index for a few thousand messages).
- **Search covers only mail on Dobby**: the first sync takes the last 100 inbox messages
  per mailbox. Searching the providers' archives is a later step.
- `SearchService` checks for the skill at use (503 when missing) instead of at start, so
  a personal bot directory without `mail-search` does not stop the server.
