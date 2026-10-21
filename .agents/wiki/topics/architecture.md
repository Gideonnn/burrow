# Architecture

Burrow is a small platform for one household: a server on Dobby (the home machine) that
hosts **modules** (Hedwig for mail, Pensieve for recordings, more later), and a native
Mac app per module built on one shared Swift package. Bots with personas do the work as
**tasks** on a shared worker pool. The plan behind this shape is
`docs/plans/2026-10-20-platform-and-pensieve.md`; the designs are in `docs/design/`
(`burrow-design-system.html` is the design system, `index.html` the latest Hedwig
iteration).

## Layout and dependency direction

```
packages/contracts   zod schemas shared by server and clients
packages/platform    @burrow/platform: the kernel
modules/<name>       a module: its tables, routes, task kinds, subjects, MCP tools
apps/server          composition root: config, wiring, login, CLI, migrations
packages/burrow-kit  Swift: BurrowKit, BurrowUI and burrowctl for every Mac app
apps/<name>-mac      one native app per module
bots/, skills/       personas and skills (data)
```

contracts ← platform ← modules ← server. The platform never imports a module and
modules never import each other; they meet through subjects, routines and events. How
to add one: [modules](modules.md).

## The platform

- **People and keys.** A person has a name, a login address (set by the operator only),
  an `admin` flag and per-person settings. An API key belongs to one person, has rights
  (read, organize, draft, send, tasks, admin) and per-module restrictions (Hedwig:
  `mailboxes`). Keys are stored as hashes. See [login and household](login-and-household.md).
- **Access.** Resolved once per request; modules extend it through `AccessExtensions`
  declaration merging (Hedwig adds `mailboxIds`). Everything outside a key's scope
  answers 404.
- **Settings.** Modules declare them (boolean, choice, text; `feature: true` for whole
  capabilities). Clients render them from `GET /api/settings/schema` without knowing
  them.
- **Shares.** `shares(module, itemId, personId)`: an owner shares one item.
- **Files and uploads.** Large files live under `<data>/files/<module>/`; uploads arrive
  in chunks of at most 32 MB (Cloudflare caps a request at 100 MB) and resume by offset.
- **Workers.** See [routines and tasks](routines.md): task kinds on a local and a cloud
  queue with priorities and pinned models, the server pool (`BURROW_WORKERS`), runners on
  the Macs (`burrowctl runner`), standing work, and at most `BURROW_AGENT_RUNS` agent CLI
  runs at once across everything.
- **Agents.** Claude Code and Codex CLIs logged in on Dobby (Codex with the ChatGPT
  plan). A bot may prefer one (`agent:` in its front matter); the other is the fallback.
  The bot's `model` is Haiku 5.5 by default; a skill that needs more says `model: opus`
  in its front matter (reply suggestions, meeting notes). Opus runs at effort high, Haiku
  chooses its own; Codex runs Sol 6.1 (`gpt-6.1-sol`) unless `BURROW_CODEX_MODEL` says
  otherwise. A bot with `agent: local` (Winky) has an `ollama:` model and is refused by
  every cloud runner, so its work never leaves the owner's Mac.
  Agents run with a clean environment: no server secret reaches a process that reads
  untrusted mail.
- **Events.** One SSE stream at `/api/events`; each event decides per key whether it may
  be seen.
- **MCP.** One endpoint; platform and modules register tools per key. See [MCP](mcp.md).

## Modules

- **Hedwig** (`modules/hedwig`): providers (Gmail API, Microsoft Graph, Fastmail JMAP;
  no IMAP), sync, the triage bot acting at the provider so phones stay calm, review of
  filtered mail, drafts, reply suggestions. The `message` subject and trigger. Triage
  keeps its own durable queue (the message records its progress). See [triage](triage.md)
  and [mail providers](providers.md).
- **Pensieve** (`modules/pensieve`): recordings uploaded by the Mac app, compressed with
  ffmpeg, transcribed through OpenAI, notes written by the bot Kreacher. The `recording`
  subject and trigger. See [Pensieve](pensieve.md).

## Clients

One native app per module (Hedwig.app, Pensieve.app), each logging in with its own
device key through the browser. They share BurrowKit (API client, device login, uploads,
events, the task runner, signed updates, the control socket) and BurrowUI (login,
Settings › Huishouden and › Workers, the palette, AppServices). Agents on the Mac operate
any running app with `burrowctl` or its MCP server: [operating the apps](agent-control.md).
Updates: [app updates](app-updates.md).
