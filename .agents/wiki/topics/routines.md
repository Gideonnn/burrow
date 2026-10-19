# Routines and tasks

A routine (Portkey) is data: a trigger, a bot, one skill, where it runs and whether a
person approves the result. Adding a routine needs no code; adding a trigger kind or a
kind of result does. Code: `apps/server/src/routines/`, contracts in
`packages/contracts/src/routines.ts`, routes `/api/routines`, `/api/tasks`, `/api/runner/*`.

## Triggers

- `message`: after triage, when every given condition holds: `label` (also the label the
  triage just added), `triage` (the decision kind), `from` and `subject` (substrings).
- `schedule`: every `everyMinutes` (at least 15), checked once a minute.

## Tasks

A trigger creates a task (`queued`). A task runs the routine's bot with exactly that
skill; the server builds the prompt (owner instructions plus the message as untrusted
text) and the answer must parse as `taskResult`: a summary, fields, provider
operations (never trash) and an optional draft. The result waits in `review` until a
person approves it (then the operations run at the provider and the draft appears in
Hedwig) or rejects it. Routines with `approval: false` apply at once.

## Where tasks run

- `server`: the server runs it right away with its own agent CLIs.
- `client`: a client app of the owner claims it (`POST /api/runner/claim`, tasks right),
  runs the request the server built with its local `claude` or `codex`, and posts the raw
  answer back; the server validates it. A claim that goes quiet for 30 minutes is
  released. With `fallbackAfterHours`, the server takes over a task no client picked up.
  Use this for skills that need the owner's computer, such as an invoice routine that
  files PDFs in iCloud (not built yet).
