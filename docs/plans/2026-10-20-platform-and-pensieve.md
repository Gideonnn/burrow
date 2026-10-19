# Platform, households and Pensieve

Plan for the refactor of 2026-10-20: Burrow becomes a small platform that hosts several
AI-assisted applications for one household (Gideon and Angela). Hedwig (mail) moves onto
it, Pensieve (meetings: record, transcribe, notes; adopted from RecHoarder) is the second
application. Decisions agreed with Gideon are marked **(agreed)**.

## Goals

- Adding an application means adding a module, not touching the platform.
- Workers (bots with a persona and skills) run tasks for a person, on Dobby or on a Mac,
  several at a time.
- Two people, both household admins: each can change the other's settings and features
  but never read the other's content (mail, recordings) unless it is shared **(agreed)**.
- Logging in on a new Mac is a browser click, not copying keys.
- No compromise on security; a UX shortcut is fine when it keeps security simple.
- Separate native apps per application, sharing one Swift package **(agreed)**.

## Layout

```
packages/contracts     zod schemas shared by server and clients (platform + per module)
packages/platform      @burrow/platform: the kernel every module builds on
modules/hedwig         mail: providers, sync, triage, drafts, routes, MCP tools
modules/pensieve       meetings: recordings, audio, transcription, notes, routes, MCP tools
apps/server            composition root: config, wiring, login, CLI, migrations
packages/burrow-kit    Swift package: API client, login, updater, runner, settings UI
apps/hedwig-mac        Hedwig.app on BurrowKit
apps/pensieve-mac      Pensieve.app on BurrowKit (capture code from RecHoarder)
bots/, skills/         personas and skills (data)
```

Dependency direction: contracts ← platform ← modules ← server. The platform never imports
a module; a module never imports another module (they talk through subjects and events).

## The platform

- **People.** `people` with name, login email, language, `admin` flag and `settings`
  (JSON). Both people are admins.
- **Devices and keys.** An API key belongs to a person, has rights (read, organize,
  draft, send, tasks, admin) and module restrictions (Hedwig: which mailboxes). A key
  made by the login flow is a *device key* named after the Mac and app. Admins list and
  revoke anyone's keys.
- **Access.** Resolved once per request from the key. Modules extend it (Hedwig adds the
  visible mailbox ids) through `AccessExtensions` declaration merging and a hook.
- **Settings and features.** Modules declare settings: key, label, description, type
  (boolean, choice, text), default, and whether only admins may change it. Values live
  per person. Clients render the settings generically from `GET /api/settings/schema`,
  so a new module's toggles appear in every app without client changes. Features are
  boolean settings named `<module>.enabled` and friends. A person edits their own; an
  admin edits anyone's (`/api/people/:id/settings`).
- **Content stays private.** Admin rights cover people, keys, settings and features.
  Routes for content check ownership (or a share), never the admin right.
- **Shares.** `shares(module, itemId, personId)`: the owner shares one item with the
  other person. Pensieve uses it; Hedwig can later share a mailbox read-only.
- **Subjects.** What a task or routine is about: `{ type: 'message' | 'recording' | …,
  id }`. Modules register subject types with: visibility for an access, the prompt
  context (trusted facts plus untrusted text), and how to apply a result. Routines and
  tasks stay module-agnostic this way.
- **Workers.** A task has a *kind*. Agent kinds build an agent request (bot persona plus
  one skill plus context) and validate the answer; code kinds run code (ffmpeg, the
  transcription API). The server runs tasks in a pool with a configurable concurrency
  (`BURROW_WORKERS`, default 2); client apps claim the kinds they can run while open. A
  task that needs approval waits in `review`. Triage keeps its own durable queue (the
  message itself records progress) but runs through the same pool.
- **Agents.** Claude Code and Codex CLIs, logged in on Dobby (Codex with the ChatGPT
  plan). A bot may name its preferred agent (`agent: codex`); the other is the fallback.
  Timeouts are per task kind (notes of a long meeting take minutes).
- **Routines (Portkey).** Trigger kinds come from modules (`message` from Hedwig,
  `recording` from Pensieve) plus the platform's `schedule`.
- **Events.** One SSE stream; every event carries its audience (a person, or a mailbox),
  and the stream filters on the key's access.
- **Files.** Large files live under `<data>/files/<module>/…` on Dobby, never in SQLite.
  Uploads are chunked (Cloudflare caps a request at 100 MB).
- **MCP.** Modules register their tools; one endpoint, per-key tool lists as today.

## Logging in

1. The app opens `https://<burrow>/login/device?app=pensieve&device=…&challenge=…&state=…&redirect=http://127.0.0.1:<port>/callback`.
2. That page is behind Cloudflare Access, so the person logs in with their household
   address; the server checks the Access token again and finds the person.
3. The page shows "Pensieve on *MacBook Angela* wants to log in as Angela" with one
   button. Only loopback redirects are accepted, so a link someone else crafted can only
   deliver the code to the clicking person's own Mac.
4. The server redirects to the loopback address with a one-time code (2 minutes).
5. The app exchanges code plus PKCE verifier at `POST /api/login/token` for a device key
   and keeps it in the Keychain.

Without Access (development), the CLI still creates keys. Admins can revoke any device.

## Pensieve

- **Recording** happens in Pensieve.app (Core Audio process tap plus microphone, the
  RecHoarder capture code). The WAV is uploaded in chunks when the recording stops, and
  an interrupted upload resumes.
- **On Dobby** **(agreed)** a code task compresses the WAV with ffmpeg to AAC, mono,
  16 kHz, 32 kbit/s (about 14 MB per hour instead of 115 MB) and deletes the WAV.
- **Transcription** is a code task through an engine interface. The first engine is
  OpenAI `gpt-4o-transcribe` with `OPENAI_API_KEY` on Dobby; audio is split by ffmpeg
  under the 25 MB and 1400 s caps. Dobby's Celeron is too slow for local Whisper. "Sign in
  with ChatGPT" (plan-billed Responses API) is a later option for the agent work, per
  person.
- **Notes** are an agent task: the bot Winky (a discreet house-elf) with the skill
  `meeting-notes` returns structure (summary, decisions, actions with owner and due date,
  open questions); the server renders the Markdown. Actions become tasks later
  (Remembrall).
- **Mirror to iCloud** **(agreed)**: Pensieve.app mirrors every recording its person can
  see (own and shared) into `iCloud Drive/Pensieve/<date>_<name>/` (audio, transcript,
  notes). Dobby keeps everything for fast lookup; the mirror doubles as a backup.
- **Import**: a menu item uploads an existing RecHoarder folder (`iCloud Drive/Meetings`)
  with its transcripts and notes.
- **MCP tools**: list and search recordings, read transcript and notes.

## Agents on the Mac operate every app

Every app is fully operable by local agents (Claude Code, Codex) **(agreed)**: read its
state, open things, prepare a draft and show it, change its own settings. Never: log
in or out, keys, server address, sending, deleting, or starting a recording; those stay
with the person (a dialog the agent cannot press, as Hedwig does today).

- BurrowKit holds the control service: each running app listens on a socket only the
  user can open (`~/Library/Application Support/Burrow/control/<app>.sock`) and
  describes its own commands (name, arguments, help).
- `burrowctl` (Swift, installed in `~/.local/bin`) finds the running apps and calls
  them: `burrowctl hedwig open <id>`, `burrowctl pensieve state`. `burrowctl mcp`
  serves the same commands as MCP tools over stdio, so `claude mcp add burrow --
  burrowctl mcp` and Codex get them as tools. `hedwigctl` stays as an alias.
- Data questions ("find the invoice from March") go to the server's MCP endpoint, which
  every module extends; UI actions go to `burrowctl`.

## Telegram (Patronus), later

A module with a bot token on Dobby. Each person links their Telegram account once
(a one-time code from the app); a group chat links to the household. Messages become
tasks for a bot; approvals arrive as inline buttons. Not built in this round.

## Checklist (everything Gideon asked for on 2026-10-20)

- [x] Platform with modules, so more AI-assisted apps plug in (office suite for the household)
- [x] Workers: bots with personas run tasks on Dobby or a Mac, several in parallel
- [x] Workers on Dobby use Claude and/or Codex (Codex on the ChatGPT plan); per bot preference
- [x] Hedwig keeps working: filtering noise, automating part of the mail
- [x] Pensieve adopts RecHoarder on the same worker system
- [x] Profiles for Gideon and Angela; both admins; manage each other's settings and features, never content
- [x] Feature flags and settings per person, rendered generically in every app
- [x] Easy and secure login (browser approval through Cloudflare Access, device keys, revocable)
- [x] Separate apps (Hedwig.app, Pensieve.app) sharing BurrowKit
- [x] Audio on Dobby, compressed with ffmpeg; mirrored to each person's iCloud (shared to both)
- [x] Every app fully operable by local agents (CLI and MCP), own settings included, nothing sensitive
- [x] Deploy to Dobby when green (allowed)
- [x] Design document with Fable (colours, type, components, screens), then iterate
- [x] Brainstorm of further apps, Telegram bot (Patronus) in the design and the plan
- [x] Sign in with ChatGPT noted as the later per-person billing option
- [x] Public home, privacy and terms pages for publishing the Google app (Gideon's step tomorrow)
- [x] Wiki, diary and TODO updated; morning summary for Gideon

## Order of work

1. `packages/platform` and the module interface; Hedwig moves into `modules/hedwig`.
2. Settings, features, admins, shares; device login.
3. Workers: task kinds, pool, subjects, client claims per kind.
4. Pensieve on the server: upload, compress, transcribe, notes, sharing, MCP.
5. BurrowKit (Swift) extracted from Hedwig: login, settings UI, control service, `burrowctl`.
6. Pensieve.app.
7. ffmpeg on Dobby, releases per app, public pages, deploy.
8. Design document (colours, type, components, screens) and the wiki.
