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

- `server`: the pool on Dobby runs `BURROW_WORKERS` tasks at once (default 2). Across
  triage, suggestions and tasks at most `BURROW_AGENT_RUNS` agent CLIs run at once.
  After a restart, tasks that were running are queued again.
- `client`: a client app of the owner claims tasks of the kinds it knows
  (`POST /api/runner/claim` with `kinds`, tasks right), runs the request the server built
  with its local `claude`, and posts the raw answer back; the server validates it. A
  claim that goes quiet for 30 minutes is released; with `fallbackAfterHours` the server
  takes over a task no client picked up. Hedwig claims `routine` tasks.

## Triggers

- `message` (Hedwig): after triage, when every given condition holds: `label` (also the
  label the triage just added), `triage` (the decision kind), `from` and `subject`
  (substrings).
- `recording` (Pensieve): when the notes are ready, optionally only if the title contains
  `title`.
- `schedule`: every `everyMinutes` (at least 15), checked once a minute.
