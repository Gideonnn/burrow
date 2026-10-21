# Routines and tasks

All work the bots and the server do in the background is a **task** on the platform's
queue; a **routine** (Portkey) is data that starts tasks when its trigger fires. Adding
a routine needs no code; adding a trigger kind or a task kind does (in a module). Code:
`packages/platform/src/workers/`, contracts in `packages/contracts/src/routines.ts`,
routes `/api/routines`, `/api/tasks`, `/api/runner/*`.

## Tasks

A task has a **kind** (`routine`, `pensieve.compress`, `pensieve.transcribe`,
`pensieve.notes`), a person, an optional **subject** (`{type: 'message' | 'recording', id}`)
and where it runs.

- **Agent kinds** build a request (bot persona plus exactly one skill plus the subject's
  prompt, untrusted text fenced) and validate the answer into a result: a summary, fields,
  provider operations (never trash) and an optional draft.
- **Code kinds** run code on the server (ffmpeg, a transcription API) and retry
  (`attempts`).
- A result waits in `review` when the kind asks for approval (routines with
  `approval: true`); otherwise it is applied at once. Failed tasks show why and can be
  retried (`POST /api/tasks/:id/retry`).
- A task about a subject is only visible to keys that can see the subject.

## Where tasks run

Every task has a **queue** (`local` or `cloud`, from its kind), a **priority** (`low`,
`normal`, `high`, `urgent`; claimed highest first, oldest first within it) and may pin a
**model** (`haiku`, `ollama:<name>`). Whatever claims tasks is a **runner** in the
`runners` table; `GET /api/runners` lists them with the work waiting per kind.

- **The server's pool** is the runner `server` (no key): `BURROW_WORKERS` tasks at once
  (default 2), only cloud tasks with `where: server`, plus cloud standing work. Across
  triage, suggestions and tasks at most `BURROW_AGENT_RUNS` agent CLIs run at once. After
  a restart, tasks that were running are queued again. An admin can pause it.
- **A Mac** runs `burrowctl runner` (see [mail facts](mail-facts.md)). Each
  `POST /api/runner/claim` (tasks right) registers it by key and name and says what it
  offers: queues, agents, local models, kinds (`*` for any). It gets cloud tasks with
  `where: client` of its own person, and of others who turned on
  `platform.shareCloudWork` (a personal setting an admin cannot change); local tasks
  only of its own person and only with a matching local model. Only the key that
  claimed a task may complete or fail it. A claim that goes quiet for 30 minutes is
  released; with `fallbackAfterHours` the server takes over a task no client picked up.
  A paused runner gets nothing.
- **Standing work** (`TaskKind.standing`): a kind that hands out the next piece of what
  is missing on each claim instead of one row per item. The row lives only while a
  runner holds it, is never listed or announced, and is deleted when done or failed;
  the module tracks attempts itself.
- A local task always runs on a local model of the runner holding it (the server sets
  the task's model at the claim), and the Mac sends every local-queue task to Ollama.
- The server's pool is known by its id, not its name: a Mac may call itself `server`.
- A standing piece whose claim times out counts as a failed attempt, so a message that
  hangs every runner is given up instead of handed out forever.
- A facts-only key cannot claim (403): task prompts carry content.

## Triggers

- `message` (Hedwig): after triage, when every given condition holds: `label` (also the
  label the triage just added), `triage` (the decision kind), `from` and `subject`
  (substrings).
- `recording` (Pensieve): when the notes are ready, optionally only if the title contains
  `title`.
- `schedule`: every `everyMinutes` (at least 15), checked once a minute.
