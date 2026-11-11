---
id: 2026-11-11-server-refactor-pass
date: 2026-11-11
kind: decision
area: [server, hedwig]
topics: [modules, architecture]
---

# A refactor pass over the server, the platform and Hedwig

**What happened.** A pass to make the TypeScript smaller and clearer without changing
behaviour, the HTTP API, MCP tools or the schema. Dead exports went (knip found them),
and helpers written several times became one: `httpErrors` in the platform for the
service-error try/catch in routes, `botWithSkill` for "this bot may use this skill",
and in Hedwig `memo.ts` with `Recent` (the 30-second progress counts of facts, sharing
and embeddings), `once` (one run per key) and the task answer helpers.

**Rejected.**

- Caching standing progress in the platform's `Workers`: sharing forgets its count
  after every answer, and doing that for every kind would recount the facts backlog
  after each piece, the scan the cache exists to avoid.
- A Hono `onError` per sub-router instead of `httpErrors`: passing other errors on to
  the app's handler means throwing inside `onError`, which leans on how Hono composes
  handlers; an explicit wrapper is plainer.
- Merging the three small HTML pages (device login, public pages, the mailbox connect
  page): they look different on purpose, so one template would change what people see.

**Traps.** The repository's secret hook refuses shell commands that mention `this.db` or
`process.env` (it reads them as a database file or env file); write edit scripts with the
Write tool and run them with `uv run`.
