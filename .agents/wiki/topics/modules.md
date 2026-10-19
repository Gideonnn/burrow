# Adding a module

A module is a workspace package in `modules/<name>` that returns a `Module`
(`packages/platform/src/module.ts`) from a factory taking the `Platform`. The server
adds it with `platform.use(...)` in `apps/server/src/main.ts` and in `testing.ts`.
Pensieve is the cleanest example to copy.

## Checklist

1. **Name** from [naming](naming.md); add it to the table there.
2. **Contracts** in `packages/contracts/src/<name>.ts`, exported from the index. The Mac
   app mirrors them in Swift.
3. **Tables** in `modules/<name>/src/schema.ts`, referencing `people` from
   `@burrow/platform`. Export them through the package's `./schema` entry and add one line
   to `apps/server/src/db/schema.ts`, then `pnpm --filter @burrow/server exec drizzle-kit
   generate --name <name>` (it prompts on renames; see the trap below).
4. **The factory** returns what applies:
   - `settings`: `<name>.enabled` as a feature, plus preferences. Check them where they
     matter (`platform.settings.enabled(personId, key)`).
   - `api`: a Hono router mounted under `/api`; guard with `requireRight` and answer
     `notFound()` for anything outside the key's scope. Owner checks, never the admin
     right, for content.
   - `subjects`: what tasks and routines can be about, with visibility, the agent prompt
     (fence untrusted text with `untrusted()`), and how to apply a result.
   - `taskKinds`: agent kinds (`agent.request`, `accept`) or code kinds (`run`), with
     `describe` for the lists and `failed` to show why. Retries via `attempts`.
   - `triggers`: a routine trigger kind, fired with `platform.routines.fire(...)`; add its
     shape to `routineTrigger` in the contracts.
   - `mcp`: tools per key; leave out anything that sends, deletes or moves money.
   - `access` and `restrictions`: only if keys can be narrowed to part of the module.
   - `clients`: the native app's name, for signed updates.
   - `start`: background loops; return a stop function.
5. **Bots and skills** as data in `bots/` and `skills/`.
6. **The Mac app** in `apps/<name>-mac`, a Swift package depending on
   `../../packages/burrow-kit`: copy Pensieve's `Package.swift`, scripts and the
   `AppDelegate` with `AppServices` (updates, restart, control socket). Register the
   app's own control commands with help texts; mark buttons that only a person may press
   `<app>.approve.<what>` and secret fields `<app>.secret.<what>`.
7. **Tests** in `apps/server/src/routes/<name>.test.ts` through `testHousehold()`, and in
   the app's core target with `MockServer`. CI builds every Swift package in the `mac` job.
8. **Wiki**: a topic for the module, the [architecture](architecture.md) list, and a diary
   entry for the decisions.

## Traps

- `drizzle-kit generate` asks whether a column was renamed and needs a TTY; through an
  agent, run it under `script -q /dev/null` and answer "create". A generated migration
  that drops a column loses its data: edit the SQL to copy values first and test the
  migration on old data (`apps/server/src/db/migrations.test.ts`).
- Modules export TypeScript source; the server bundle inlines `@burrow/*` (tsup
  `noExternal`). Add new packages to `apps/server/Dockerfile`.
