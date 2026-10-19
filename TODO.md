# TODO

Issue-ready entries, roughly in build order. Delete an entry in the commit that finishes it.

## Hedwig: Gmail provider

**What:** a `MailProviderClient` for the Gmail API: OAuth (the Mac app runs the browser
login with PKCE and hands the code to the server), sync with `history.list`, and `apply`
for the server operations. Tokens encrypted at rest.
**Why:** the old private Gmail address is the main source of spam.
**Scope:** provider plus fixtures-based tests; no real mailbox in tests.

## Hedwig: Microsoft Graph and Fastmail JMAP providers

**What:** the same interface for Graph (delta queries, polling) and JMAP (EventSource push,
API token). **Why:** the other accounts. **Scope:** one PR per provider.

## Triage with bots and skills

**What:** a runner on the server that hands a new message, the owner's instructions and a
bot's skills to `claude -p --model <bot.model>` and validates the JSON against
`triageAction`; applies `serverOpsFor` at the provider; keeps a log for the "Gefilterd"
review with restore. **Why:** the core of Hedwig. **Scope:** runner, log, restore, tests
with a fake agent CLI.

## MCP endpoint

**What:** `/mcp` on the server (streamable HTTP), authenticated with an API key and scoped
by its mailboxes and rights: search, read, organize, draft. **Why:** Claude Code and Codex
must use the mail. **Scope:** one PR.

## Hedwig for macOS

**What:** `apps/hedwig-mac` in SwiftUI: connect screen (server URL and key), per-account
inboxes, reading, replying, Gefilterd review. Decide between an XcodeGen `project.yml` and
a Swift package with a bundling script before starting. Raycast alias `email`.
**Why:** the primary mail app. **Scope:** several PRs, screen by screen.

## Deploy to Dobby

**What:** Dockerfile and Compose for the server, `tailscale serve` for HTTPS, nightly
encrypted backup of the database, deploy configuration in SOPS with age (recipients:
Gideon's Mac and Dobby). **Why:** run it at home. **Scope:** `infra/` plus a runbook topic.

## Routines, task queue and runners on clients

**What:** Portkey routines as data (trigger plus task type plus skill), the task queue, and
runners in client apps. Invoice processing is the first routine. **Why:** household
automation beyond mail. **Scope:** design note first.

## Open-source readiness

**What:** choose a licence, add GitHub Actions (format check, lint, typecheck, tests, hook
tests) and gitleaks, and review `docs/design/` for personal details before going public.
**Why:** the repository may become public. **Scope:** one PR.
