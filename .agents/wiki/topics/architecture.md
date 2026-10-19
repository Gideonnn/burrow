# Architecture

The Burrow server (`apps/server`), running on Dobby, a small Linux machine at home, owns everything that must keep running:
mail sync, the agent triage, the task queue, people, API keys and the MCP endpoint.
Clients (the Hedwig Mac app, Claude Code, Codex) are thin: they show what their API key
allows and send actions back. The designs in `docs/design/` show the intended product;
`index.html` is the latest iteration.

## Server and modules

- `apps/server` is one process that hosts every module. A module (for example
  `modules/hedwig`) contributes routes, storage and task types; the server provides auth,
  people, keys, runners, routines and skills.
- Storage is SQLite on the server. Provider OAuth tokens are encrypted at rest; API keys are
  stored only as hashes.
- The server binds to localhost by default and is reached through Tailscale (`tailscale
  serve` for HTTPS), so no port on the home router is opened.

## Hedwig (mail)

- Providers are reached through their own APIs: the Gmail API, Microsoft Graph and
  Fastmail JMAP. IMAP is not used: the APIs give push or delta sync, labels/categories
  and scoped OAuth.
- The triage agent acts **on the server side** of the provider: spam to the provider's
  spam folder, noise archived, everything filtered marked read, "needs reply" flagged.
  Phones using the native mail apps therefore stay calm. `serverOpsFor` in
  `modules/hedwig` maps a triage decision to provider operations.
- Filtered mail is reviewed in the client ("Gefilterd"); restoring a message undoes the
  server operations and teaches a rule for that person.

## People, keys and rights

A person owns mailboxes, agent instructions and learned rules. An API key belongs to one
person and is limited to a subset of that person's mailboxes and to rights: read,
organize, draft, send, tasks, admin. A key never sees anything outside its mailboxes:
not in lists, search, counts, the agent log or MCP.

## Runners, routines and skills

- A **task** sits in a queue on the server with a type, person, source and where it may run.
- A **runner** executes tasks: the server itself (always on on Dobby) or a client app while it is open.
  A runner uses the agent CLIs logged in on its own machine (`claude -p`, `codex exec`)
  and only picks up tasks within its key.
- A **routine** (Portkey) is a configurable trigger that creates tasks: a new mail with a
  label, a time, later other events. Invoice processing will be a routine; it is not
  built yet, but the model must allow routines to be added without code changes.
- A **skill** (in `skills/`) is a folder with instructions and tool declarations that a
  runner hands to the agent, like a Claude skill. Task types reference skills.
- A **bot** is a persona in one markdown file (in `bots/`, plus a personal directory on
  the server): front matter for name, model, skills and rights, the body for its
  character, in the same shape as a Claude Code subagent. Kreacher is the first bot.
  Bots are data, so the code never names a persona; `loadCatalog` in `apps/server`
  validates bots and skills at startup and refuses a bot with `send` or `admin`.

## Clients

- Hedwig for macOS is native SwiftUI. Raycast opens it through the alias `email`.
- Clients connect with a server URL and an API key, and receive live updates over a
  WebSocket.
