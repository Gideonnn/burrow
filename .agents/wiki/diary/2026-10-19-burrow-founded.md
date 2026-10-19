---
id: 2026-10-19-burrow-founded
date: 2026-10-19
kind: decision
area: [hedwig, server, repo]
topics: [architecture, naming]
---

# Burrow founded

The repository started from four design iterations of a mail client
(`docs/design/v1.html` to `index.html`). Decisions, with the alternatives rejected:

- **Provider APIs, not IMAP.** Gmail API, Microsoft Graph and Fastmail JMAP. IMAP would
  have been one code path, but loses push/delta sync, labels and scoped OAuth.
- **Per-account inboxes, no unified inbox.** Chosen by Gideon after seeing both.
- **Server and client split.** A unified local app was rejected because the agent must
  keep filtering while the Mac sleeps, and a second person's mailboxes need scoped access.
- **Agent acts on the provider, not only in the app.** Gideon reads mail on phones with
  the native apps; filtering only inside Hedwig would leave those noisy.
- **Native SwiftUI client from the start.** Electron and Tauri were rejected.
- **No T3 Code coupling; MCP only.** Creating T3 threads from mail was rejected; Claude
  Code and Codex reach the server through MCP with their own scoped keys.
- **Runners on server and client, routines and skills as data.** Invoice processing is
  the first routine but is deferred; the model must allow new routines without code.
- **Overview home screen deferred** to keep the first version small.
- **Names from Harry Potter.** Meterkast, Postkamer and Huisraad were considered;
  the theme won because it scales to many household helpers.
- **The server is not called Dobby.** Dobby is already the name of the home machine, so
  the server is plainly `apps/server`. Kreacher became a bot persona instead of a
  component: Gideon wants many bots defined in markdown files, so no implementation
  carries a persona's name.
