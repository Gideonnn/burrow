# 2026-10-22 Runners, two queues and mail facts in one night

Built the whole plan of 2026-10-20 (phases 1 to 7) and deployed it.

## Decisions

- **The claim is the registration.** A runner registers on its first
  `POST /api/runner/claim` and each claim is its heartbeat, so the old Hedwig app keeps
  working unchanged and shows up as a runner too. No separate register call.
- **Standing work as short-lived task rows.** A row exists only while a runner holds a
  piece (one message, twenty templates), is never listed or announced, and is deleted
  when done or failed. The module keeps attempts itself. This reuses claim, complete,
  fail and the 30-minute release instead of a second mechanism.
- **The answer travels in `TaskResult.fields.answer`.** The generic result type has no
  room for facts, and `accept` must not write; JSON in one field keeps the platform
  ignorant of Hedwig.
- **Templates stay on sender plus subject pattern.** Phase 0 suggested grouping by sender
  for category and priority; not done, because a per-sender answer would still need
  Winky for summary and keywords and saves no model time.
- **Not built:** moving agent work about a sensitive message to the local queue (no local
  bot has those skills; the cloud gets the redacted body instead), and idle cloud tasks
  on a local model (built at first, removed in review: unused, and it would have let one
  person's cloud task run on another's local model). Pensieve transcripts are not hidden from facts-only keys.
- **Runner keys have only `read` and `tasks`**, from the device login (`app: runner`) or
  the CLI.

## Traps

- **launchd refused the job with exit 78** (`EX_CONFIG`): started from PATH, `argv[0]` is
  a bare name, so the plist pointed at `<cwd>/burrowctl`. `Bundle.main.executableURL`
  gives the real path.
- **An invisible keychain prompt blocks the runner.** Each ad-hoc build of `burrowctl` is
  a new app to the keychain; `runner install` and `runner run` hung on reading the key.
  Fix: sign with the Apple Development identity (team ID), then log in once more.
- **A test that broke by itself:** the triage retry test used the fake provider's fixed
  date with `retryUntriaged()`'s "last two days" window, so it failed from 2026-10-22 on.
  The test now passes its own `since`.
- The repository's pre-tool hook blocks shell commands that contain `this.o.db` or `d.key`
  as "plaintext secrets"; write such code with the editor tools, not heredocs.
- Ollama takes the zod-generated JSON schema (`$schema`, `additionalProperties`,
  `maxLength`, `pattern`) as is.
- **A review the same night** found that facts-only keys could still claim task prompts
  (raw bodies) and read draft and filtered snippets, that standing pieces ignored a
  key's mailbox scope, that a hanging message was handed out forever, that a Mac named
  `server` could never finish a task, and that `ensureTemplates` and the backlog query
  would have rewritten or sorted tens of thousands of rows per claim on the Celeron. All
  fixed with tests.
