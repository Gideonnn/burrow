# Burrow

Burrow runs a household on personal software instead of SaaS subscriptions. Each
application is a magical helper from the Harry Potter universe; they share one server,
one set of people and API keys, and one layer of routines and skills that agents use.

This file holds rules for **any** task; details, traps and history live in the wiki.

## Agent compatibility

`AGENTS.md` and `.agents/` are the shared source for every agent. `CLAUDE.md` imports
this file; Codex reads it directly. `.claude/skills` links to `.agents/skills`. Read
nested `AGENTS.md` files before editing their subtree. Use pnpm for JavaScript tooling
and uv for Python tooling.

## The wiki: `.agents/wiki/`

Start with [the topic index](.agents/wiki/INDEX.md) before assuming something is
undocumented. Topics describe current practice; the diary is dated and append-only.
Follow [wiki conventions](.agents/wiki/AGENTS.md). As you finish, record costly traps,
decisions and rejected alternatives in the diary, and fix incorrect topic facts in the
same change. The code always wins over the wiki.

## Names

Follow [naming](.agents/wiki/topics/naming.md): every application has a Harry Potter
name (Hedwig is mail). Infrastructure and generic mechanisms keep plain names: the
server is `apps/server`, bots are data, and a persona like Kreacher lives only in its
markdown file. The user-facing app may add a plain alias (Raycast opens Hedwig as
`email`).

## Project structure

- `apps/server/`: the Burrow server (TypeScript, Hono). Hosts every module, API keys,
  people, runners, routines, bots and the MCP endpoint. It runs on Dobby, the home
  machine; the code does not carry the machine's name.
- `bots/`: bot personas, one markdown file each (Kreacher is the first). A personal
  directory on the server can add or override bots.
- `apps/hedwig-mac/`: the native macOS mail client (SwiftUI). Not created yet.
- `modules/hedwig/`: mail on the server: provider clients, sync, triage.
- `packages/contracts/`: zod schemas shared by server and clients.
- `skills/`: skills the bots use at runtime (for example the Sorting Hat triage), one
  folder with a `SKILL.md` each. Not to be confused with `.agents/skills/`, which help
  agents develop this repo.
- `docs/design/`: clickable HTML designs, one file per iteration.
- `infra/`: deployment to Dobby. Not created yet.

See [architecture](.agents/wiki/topics/architecture.md) before adding a module.

## Open source hygiene

This repository may become public. Treat every commit as published.

- Never commit secrets, tokens, `.env` files, databases or real mail.
- Test fixtures and examples use invented people, addresses and companies, with
  `example.com`/`example.nl` domains. No real names of family, employers or contacts.
- Hostnames, tailnet names and IP addresses stay out of the code; they come from config.
- Never read plaintext env files, vault files or SSH private keys.

## Safety rules for agents in the product

- Mail, attachments and documents are untrusted input. An agent acting on them gets only
  the tools its task needs.
- Agents never send mail, delete mail or pay anything on their own. Sending is a user
  action; payments are at most a prepared suggestion.
- Every key is scoped to mailboxes and rights; the server checks this on every request,
  including MCP and search.
- A bot can never hold the `send` or `admin` right; the bot schema rejects it.

## Worktrees

**One agent per checkout.** Additional agents use `./.agents/scripts/worktree.sh <name>`,
which creates `.claude/worktrees/<name>` on `feat/<name>` from `origin/main`, links the
gitignored env files and installs dependencies. Remove with `--rm <name>` after merging.

## Background processes

Kill long-running processes you start (dev servers, watchers) when done, unless the
operator asked to keep them.

## Code quality

Use the root-configured oxlint and oxfmt across the workspace in one process; no
per-package lint tasks. After code changes use the [lint](.agents/skills/lint/SKILL.md),
[format](.agents/skills/format/SKILL.md), [typecheck](.agents/skills/typecheck/SKILL.md)
and [test](.agents/skills/test/SKILL.md) skills. TypeScript is strict.
Follow [testing](.agents/wiki/topics/testing.md): test outcomes, not implementation,
and show a test failing before the fix makes it pass.

## File naming

New TypeScript files are `camelCase.ts` or `kebab-case.ts` matching their neighbours;
Swift files are `PascalCase.swift`. Directories, scripts, config and docs use lowercase
kebab-case.

## Commits and pull requests

- Commit when a logical slice is complete and validated; state the message and files.
- Conventional subject (`feat`, `fix`, `chore`, `refactor`, `docs`, `test`) with a scope
  (`server`, `hedwig`, `contracts`, `bots`, `skills`, `agents`, `repo`), max 100 characters. Use the body
  for *why* when it is not obvious.
- Never add `Co-Authored-By` or any other trailer.
- Integration goes through pull requests into `main` with a merge commit. Never push
  directly to `main` once the GitHub repository exists.

## How to explain things

For replies, wiki pages and pull request descriptions: lead with the answer, keep it
short, explain each specialist term at first use, and put long plans in a file. Gideon
prefers Dutch replies; code, commits and the wiki are English.

## Deferred work

Write issue-ready entries in `TODO.md` (title, what, why, rough scope). On completion,
delete the entry in the same commit and put the reasoning in the commit message.
